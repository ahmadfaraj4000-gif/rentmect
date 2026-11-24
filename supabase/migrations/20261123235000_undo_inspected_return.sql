begin;
create table public.rental_return_reversals (
  inspection_id uuid primary key,
  rental_id uuid not null references public.rentals(id),
  prior_rental jsonb not null, prior_vehicle jsonb not null, prior_assignment jsonb,
  inspection jsonb not null, created_at timestamptz not null default now(),
  reversed_at timestamptz, reversed_by uuid references auth.users(id)
);
create index on public.rental_return_reversals(rental_id,created_at desc);
create table public.rental_recovery_attempts (
  actor_id uuid primary key references auth.users(id), failures integer not null default 0, started_at timestamptz not null default now()
);
alter table public.rental_return_reversals enable row level security;
alter table public.rental_recovery_attempts enable row level security;
revoke all on public.rental_return_reversals,public.rental_recovery_attempts from public,anon,authenticated;

-- Capture the precise values before the inspection RPC mutates assignment, rental and vehicle.
create function public.snapshot_return_for_recovery() returns trigger
language plpgsql security definer set search_path=public as $$
declare r rentals; v vehicles; a rental_vehicle_assignments;
begin
  select * into strict r from rentals where id=new.rental_id for update;
  select * into strict v from vehicles where id=r.vehicle_id for update;
  select * into a from rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from
    order by assigned_from desc,created_at desc,id desc limit 1 for update;
  insert into rental_return_reversals(inspection_id,rental_id,prior_rental,prior_vehicle,prior_assignment,inspection)
  values(new.id,r.id,jsonb_build_object('status',r.status,'starting_mileage',r.starting_mileage,'ending_mileage',r.ending_mileage,
    'prior_vehicle_miles',r.prior_vehicle_miles,'mileage_history_complete',r.mileage_history_complete,
    'deposit_status',r.deposit_status,'deposit_release_due_at',r.deposit_release_due_at,'deposit_release_reason',r.deposit_release_reason,
    'deposit_release_error',r.deposit_release_error,'return_initiated_at',r.return_initiated_at),
    jsonb_build_object('id',v.id,'status',v.status,'current_mileage',v.current_mileage),
    jsonb_build_object('id',a.id,'starting_mileage',a.starting_mileage,'ending_mileage',a.ending_mileage),to_jsonb(new));
  return new;
end $$;
revoke all on function public.snapshot_return_for_recovery() from public,anon,authenticated;
create trigger snapshot_return_for_recovery before insert on public.rental_return_inspections
for each row execute function public.snapshot_return_for_recovery();

-- The code is provisioned under rental_return_recovery_code in Supabase Vault.
create function public.undo_rental_return(p_rental_id uuid,p_code text,p_inspected_at timestamptz) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.rentals; v public.vehicles; s public.rental_return_reversals; a public.rental_recovery_attempts;
  old_r public.rentals; secret text; inspection public.rental_return_inspections;
  old_rental jsonb; old_vehicle jsonb; assignment jsonb;
begin
  if public.rental_operations_staff_name() is null then raise exception 'Rental operations access required.' using errcode='42501'; end if;
  insert into public.rental_recovery_attempts(actor_id) values(auth.uid()) on conflict do nothing;
  select * into strict a from public.rental_recovery_attempts where actor_id=auth.uid() for update;
  if a.started_at<=clock_timestamp()-interval '15 minutes' then
    update public.rental_recovery_attempts set failures=0,started_at=clock_timestamp() where actor_id=auth.uid();
  elsif a.failures>=5 then return jsonb_build_object('error','Too many attempts. Try again after 15 minutes.'); end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name='rental_return_recovery_code';
  if nullif(secret,'') is null then raise exception 'Recovery code has not been configured.'; end if;
  if p_code is distinct from secret then
    update public.rental_recovery_attempts set failures=failures+1 where actor_id=auth.uid();
    return jsonb_build_object('error','Incorrect return recovery code.'); end if;
  update public.rental_recovery_attempts set failures=0,started_at=clock_timestamp() where actor_id=auth.uid();
  select * into strict r from public.rentals where id=p_rental_id for update;
  select * into s from public.rental_return_reversals where rental_id=r.id and created_at=p_inspected_at order by created_at desc limit 1 for update;
  if s.reversed_at is not null then return jsonb_build_object('status','already_reversed'); end if;
  if r.status<>'completed' or r.inspection_completed_at is distinct from p_inspected_at then raise exception 'Rental return changed. Refresh before continuing.'; end if;
  if s.inspection_id is null then
    select * into inspection from public.rental_return_inspections
      where rental_id=r.id and created_at=p_inspected_at;
    select old_values into old_rental from public.admin_audit_logs
      where entity_type='rental' and entity_id=r.id::text and created_at=p_inspected_at
        and old_values->>'status' in ('active','rented','overdue','return_initiated') and new_values->>'status'='completed';
    select old_values into old_vehicle from public.admin_audit_logs
      where entity_type='vehicle' and entity_id=r.vehicle_id::text and created_at=p_inspected_at
        and (new_values->>'current_mileage')::integer is not distinct from coalesce(inspection.ending_mileage,(old_values->>'current_mileage')::integer)
      order by id limit 1;
    if inspection.id is null or old_vehicle is null or old_rental is null or old_rental->>'ending_mileage' is not null
      or (select count(*) from public.rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from)>1 then
      raise exception 'The return audit cannot establish the prior vehicle assignment or mileage. Reconcile it before reopening.';
    end if;
    select jsonb_build_object('id',id,'starting_mileage',starting_mileage,'ending_mileage',null) into assignment
      from public.rental_vehicle_assignments where rental_id=r.id and vehicle_id=r.vehicle_id and assigned_until>assigned_from
        and ending_mileage is not distinct from inspection.ending_mileage;
    if assignment is null and exists(select from public.rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from) then
      raise exception 'Vehicle assignment changed after inspection.';
    end if;
    insert into public.rental_return_reversals(inspection_id,rental_id,prior_rental,prior_vehicle,prior_assignment,inspection,created_at)
      values(inspection.id,r.id,old_rental,old_vehicle,assignment,to_jsonb(inspection),p_inspected_at) returning * into s;
  end if;
  perform pg_advisory_xact_lock(hashtext(r.vehicle_id::text));
  select * into strict v from public.vehicles where id=r.vehicle_id for update;
  if r.vehicle_id is distinct from (s.prior_vehicle->>'id')::uuid or exists(select from public.rental_vehicle_assignments where vehicle_id=r.vehicle_id and rental_id<>r.id and created_at>=s.created_at)
    or exists(select from public.rentals where id<>r.id and vehicle_id=r.vehicle_id and status in ('active','rented','overdue','return_initiated'))
  then raise exception 'Vehicle reassigned. Reconcile the conflicting assignment before reopening.'; end if;
  if exists(select from public.rental_payment_refunds where rental_id=r.id and created_at>=s.created_at and status not in ('failed','cancelled'))
    or exists(select from public.deposit_review_settlements where rental_id=r.id and created_at>=s.created_at)
    or exists(select from public.rental_deposit_allocations where holder_rental_id=r.id and (refund_reserved_amount>0 or refund_requested_at>=s.created_at or refund_completed_at>=s.created_at))
    or r.deposit_review_approved_at>=s.created_at or r.deposit_released_at>=s.created_at
    then raise exception 'Deposit settlement or refund recorded. Reconcile it before reopening.'; end if;
  if exists(select from public.vehicle_reports where rental_id=r.id and created_at>=s.created_at and report_type='admin_return_damage')
    or (v.status in ('maintenance','unavailable','inactive','retired') and v.status is distinct from s.prior_vehicle->>'status')
    then raise exception 'Resolve the return inspection case or vehicle restriction before reopening.'; end if;
  if v.current_mileage is distinct from coalesce((s.inspection->>'ending_mileage')::integer,(s.prior_vehicle->>'current_mileage')::integer)
    then raise exception 'The odometer changed after return. Reconcile mileage before reopening.'; end if;
  if exists(select from public.email_outbox where rental_id=r.id and created_at=s.created_at and status='processing') then
    raise exception 'A return notice is being delivered. Retry after delivery finishes.'; end if;
  old_r:=jsonb_populate_record(null::public.rentals,s.prior_rental);
  update public.rental_vehicle_assignments set starting_mileage=(s.prior_assignment->>'starting_mileage')::integer,
    ending_mileage=(s.prior_assignment->>'ending_mileage')::integer where id=(s.prior_assignment->>'id')::uuid;
  delete from public.rental_return_inspections where id=s.inspection_id;
  update public.rentals set status=old_r.status,starting_mileage=old_r.starting_mileage,ending_mileage=old_r.ending_mileage,
    prior_vehicle_miles=old_r.prior_vehicle_miles,mileage_history_complete=old_r.mileage_history_complete,
    inspection_completed_at=null,deposit_status=old_r.deposit_status,deposit_release_due_at=old_r.deposit_release_due_at,
    deposit_release_reason=old_r.deposit_release_reason,deposit_release_error=old_r.deposit_release_error,
    return_initiated_at=old_r.return_initiated_at where id=r.id;
  update public.vehicles set status=s.prior_vehicle->>'status',current_mileage=(s.prior_vehicle->>'current_mileage')::integer where id=v.id;
  delete from public.deposit_action_tasks where rental_id=r.id and created_at=s.created_at and status in ('action_required','blocked');
  update public.email_outbox set status='cancelled',last_error='Return reversed' where rental_id=r.id and created_at=s.created_at
    and status in ('pending','failed') and email_type in ('security_deposit_refund','deposit_release','rental_return');
  update public.rental_return_reversals set reversed_at=clock_timestamp(),reversed_by=auth.uid() where inspection_id=s.inspection_id;
  insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload) values
    (r.id,r.user_id,auth.uid(),'admin_return_reversed',jsonb_build_object('inspection_id',s.inspection_id,'restored_status',old_r.status));
  return jsonb_build_object('status','reversed');
end $$;
revoke all on function public.undo_rental_return(uuid,text,timestamptz) from public,anon;
grant execute on function public.undo_rental_return(uuid,text,timestamptz) to authenticated;
commit;
