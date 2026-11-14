begin;
set local lock_timeout='2s';
set local statement_timeout='30s';

-- Possession and lateness are independent. The scheduled end never releases a car.
create or replace function public.rentmect_requires_physical_return_lock(p_status text,p_return_date date,p_return_time text)
returns boolean language sql stable set search_path=public as $$
 select lower(coalesce(p_status,'')) in ('active','rented','overdue','return_initiated');
$$;
create or replace function public.rentmect_is_rental_overdue(p_status text,p_return_date date,p_return_time text)
returns boolean language sql stable set search_path=public as $$
 select lower(coalesce(p_status,'')) in ('active','rented','overdue') and p_return_date is not null
 and now() >= (public.rentmect_rental_timestamp(p_return_date,p_return_time) at time zone 'America/New_York');
$$;
revoke all on function public.rentmect_is_rental_overdue(text,date,text) from public,anon;
grant execute on function public.rentmect_is_rental_overdue(text,date,text) to authenticated,service_role;

-- Compatible no-op for old scheduled jobs and retries. No automatic assessments.
create or replace function public.rentmect_stage_late_return_charges(p_as_of timestamptz default now())
returns integer language sql security definer set search_path=public as $$ select 0; $$;
revoke all on function public.rentmect_stage_late_return_charges(timestamptz) from public,anon,authenticated;
grant execute on function public.rentmect_stage_late_return_charges(timestamptz) to service_role;

-- Preserve the installed definitions, permissions and pricing wrappers. Only remove
-- availability buffers from explicitly selected readers/writers, never pre-due reminders.
do $$ declare f record; definition text; begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prokind='f' and p.proname in (
 'rentmect_vehicle_conflicts','enforce_rental_schedule_integrity','enforce_pending_booking_schedule_integrity',
 'admin_create_manual_rental','admin_preview_rental_amendment','admin_preview_rental_amendment_without_manual_discount',
 'create_website_pending_booking','create_website_booking','get_admin_calendar_fleet_availability','get_admin_calendar_events',
 'get_available_vehicles','get_vehicle_booking_blocks','validate_rental_extension_request',
 'record_admin_local_rental_extension_payment','admin_rental_list','admin_rental_summary_changes',
 'request_customer_vehicle_switch_continuation','admin_mark_rental_active',
 'request_customer_rental_extension_before_periods','record_stripe_checkout_payment',
 'rentmect_normalize_status_after_schedule_change','preview_customer_rental_extension_v2',
 'decide_admin_rental_extension','sync_extension_calendar_hold','preview_customer_rental_extension',
 'enforce_extension_pending_checkout_integrity','admin_activate_rental_with_emergency_exception',
 'preview_customer_vehicle_switch_continuation','create_rental_with_lock','admin_restore_cancelled_unpaid_rental',
 'rentmect_extension_pending_checkout_conflict','preview_customer_vehicle_switch_continuation_v2') loop
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,'''3 hours''','''0 hours''');
  definition:=replace(definition,'three-hour turnaround protected','exact reservation times');
  definition:=replace(definition,'OVERDUE — PHYSICAL RETURN REQUIRED','OUT — ADMIN-CONFIRMED RETURN REQUIRED');
  definition:=replace(definition,'another rental or its three-hour turnaround occupies this time','another rental occupies this time');
  definition:=replace(definition,'three-hour turnaround, ','');
  definition:=replace(definition,'reserved dates or three-hour turnaround','reserved dates');
  if position('extension' in (select proname from pg_proc where oid=f.oid))>0 or
     (select proname from pg_proc where oid=f.oid)='record_stripe_checkout_payment' then
    definition:=replace(definition,'coalesce(lower(r.status), '''') <> ''cancelled''','coalesce(lower(r.status), '''') not in (''completed'',''cancelled'')');
  end if;
  execute definition;
 end loop;
 -- The overdue reconciler must not use the possession predicate.
 definition:=pg_get_functiondef('public.reconcile_overdue_rentals()'::regprocedure);
 definition:=replace(definition,'rentmect_requires_physical_return_lock','rentmect_is_rental_overdue');
 definition:=replace(definition,'''3 hours''','''0 hours''');
 definition:=replace(definition,'perform public.rentmect_stage_late_return_charges(now());','');
 definition:=replace(definition,'''late_charge_staged'', true','''late_charge_staged'', false');
 definition:=replace(definition,'''grace_period_minutes'', 180','''grace_period_minutes'', 0');
 execute definition;
end $$;

-- Legacy customer recommendation lists must use the same possession/hold checks.
do $$ declare item record; d text; needle text; added text; begin
 for item in select * from (values
  ('preview_customer_rental_extension','vehicles','v_current_return_at','v_requested_return_at'),
  ('preview_customer_vehicle_switch_continuation','vehicles','v_switch_start_at','v_requested_return_at'),
  ('preview_customer_vehicle_switch_continuation_v2','vehicle','v_start_at','v_end_at')
 ) as x(name,alias_name,start_name,end_name) loop
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname=item.name;
  needle:='where '||item.alias_name||'.id <> v_rental.vehicle_id';
  if position(needle in d)=0 then raise exception 'Customer recommendation baseline changed: %',item.name; end if;
  added:=needle||' and not exists(select 1 from public.rentmect_vehicle_conflicts('||item.alias_name||'.id,'||
   item.start_name||' at time zone ''America/New_York'','||item.end_name||' at time zone ''America/New_York'',v_rental.id))';
  d:=replace(d,needle,added);
  d:=replace(d,'coalesce(lower(booked.status), '''') <> ''cancelled''','coalesce(lower(booked.status), '''') not in (''completed'',''cancelled'')');
  execute d;
 end loop;
end $$;

-- Existing future reservations remain editable for bookkeeping; they do not permit
-- a new pickup while the preceding car is out. Return completion cannot be blocked
-- by a later booking, checkout hold or a newly added maintenance block.
do $$ declare d text; marker text:='begin'; insertion text; begin
 select pg_get_functiondef('public.enforce_rental_schedule_integrity()'::regprocedure) into d;
 insertion:=$guard$begin
  if tg_op='UPDATE' then
    if new.status in ('completed','cancelled') then return new; end if;
    if new.vehicle_id is not distinct from old.vehicle_id
       and new.pickup_date is not distinct from old.pickup_date
       and new.pickup_time is not distinct from old.pickup_time
       and new.return_date is not distinct from old.return_date
       and new.return_time is not distinct from old.return_time
       and not (new.status in ('active','rented') and old.status not in ('active','rented','overdue','return_initiated')) then
      return new;
    end if;
  end if;
$guard$;
 if position(marker in d)=0 then raise exception 'Rental schedule guard baseline changed'; end if;
 d:=overlay(d placing insertion from position(marker in d) for length(marker));
 execute d;
end $$;

create function public.rentmect_guard_physical_return_transition() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 -- A continuation is a new rental, but pickup still requires the previous car back.
 if new.status in ('active','rented') and old.status not in ('active','rented','overdue','return_initiated') then
  if exists(select 1 from public.rental_extension_requests e join public.rentals parent on parent.id=e.rental_id
    where e.replacement_rental_id=new.id and e.request_kind='switch_car_continuation'
      and public.rentmect_requires_physical_return_lock(parent.status,parent.return_date,parent.return_time)) then
   raise exception 'Confirm the original vehicle’s physical return before handing over this continuation vehicle.';
  end if;
 end if;
 if tg_op='UPDATE' and public.rentmect_requires_physical_return_lock(old.status,old.return_date,old.return_time) then
  if new.status='cancelled' then raise exception 'This vehicle is still out. Confirm its physical return before cancelling or closing the rental.'; end if;
  if new.status='completed' and new.inspection_completed_at is null then
   raise exception 'Complete the admin return inspection before marking this rental returned.'; end if;
  if new.status not in ('active','rented','overdue','return_initiated','completed') then
   raise exception 'This vehicle remains out until admin-confirmed return. Changing its booking status cannot release it.'; end if;
  if new.vehicle_id is distinct from old.vehicle_id and nullif(current_setting('rentmect.vehicle_swap',true),'') is null then
   raise exception 'Use the protected vehicle swap and confirm the physical handover before changing an occupied vehicle.'; end if;
 end if;
 return new;
end $$;
revoke all on function public.rentmect_guard_physical_return_transition() from public,anon,authenticated;
create trigger aaaa_physical_return_transition before update of status,vehicle_id on public.rentals
for each row execute function public.rentmect_guard_physical_return_transition();

-- All producers are disabled, including accidental direct legacy inserts.
create function public.rentmect_reject_automatic_late_charge() returns trigger
language plpgsql set search_path=public as $$
begin
 if new.source_type='late_return' then raise exception 'Automatic late-return charges are disabled. An administrator must explicitly approve any manual charge.'; end if;
 return new;
end $$;
revoke all on function public.rentmect_reject_automatic_late_charge() from public,anon,authenticated;
create trigger aaaa_no_automatic_late_charge before insert on public.rental_charge_items
for each row execute function public.rentmect_reject_automatic_late_charge();
-- Preserve maintenance restrictions during return; clearing them is a separate admin action.
do $$ declare d text; sig text; begin
 foreach sig in array array['public.admin_inspect_and_complete_rental_return_core(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean)'] loop
  d:=pg_get_functiondef(sig::regprocedure);
  if position('set status = p_vehicle_disposition,' in d)=0 then raise exception 'Return disposition baseline changed'; end if;
  d:=replace(d,'set status = p_vehicle_disposition,',
   'set status = case when p_vehicle_disposition = ''available'' and status in (''maintenance'',''unavailable'',''inactive'',''retired'') then status else p_vehicle_disposition end,');
  execute d;
 end loop;
end $$;
-- The obsolete two-argument endpoint has no physical-inspection confirmation.
create or replace function public.admin_complete_rental_return(p_rental_id uuid,p_ending_mileage integer)
returns public.rentals language plpgsql security definer set search_path=public as $$
begin raise exception 'Complete the admin return inspection to confirm physical return, mileage, fuel, condition, and vehicle disposition.'; end $$;

-- A protected swap is the admin's physical-return confirmation for the outgoing car.
-- The existing RPC requires both verified odometers and an audited reason.
do $$ declare d text; begin
 d:=pg_get_functiondef('public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,integer,integer)'::regprocedure);
 d:=replace(d,'''active'',''rented'',''overdue'',''return_initiated'',''completed''','''active'',''rented'',''overdue'',''return_initiated''');
 execute d;
 d:=pg_get_functiondef('public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text,integer,integer)'::regprocedure);
 if position(' return result;' in d)=0 then raise exception 'Swap baseline changed'; end if;
 d:=replace(d,' return result;',$handover$
 -- Maintenance swaps cannot accidentally publish the returned vehicle.
 update public.vehicles set status=case
  when status in ('maintenance','unavailable','inactive','retired') then status
  when p_swap_kind='maintenance' then 'maintenance' else 'available' end
 where id=r.vehicle_id;
 update public.vehicles set status='rented' where id=p_vehicle_id
 and status not in ('maintenance','unavailable','inactive','retired');
 insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
 values(r.id,r.user_id,auth.uid(),'admin_swap_physical_handover',jsonb_build_object(
  'swap_id',p_idempotency_key,'returned_vehicle_id',r.vehicle_id,'replacement_vehicle_id',p_vehicle_id,
  'effective_at',p_effective_at,'outgoing_mileage',p_outgoing_mileage,'incoming_mileage',p_incoming_mileage));
 return result;
$handover$);
 execute d;
end $$;

do $$ declare f record; d text; begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('queue_due_rental_return_email_reminders','claim_due_rental_return_sms_reminders') loop
  d:=pg_get_functiondef(f.oid);
  d:=replace(d,'rentals_due.due_at + interval ''3 hours''','rentals_due.due_at');
  execute d;
 end loop;
end $$;

-- Existing extension holds also lose their stored buffer, without touching manual blocks.
update public.vehicle_availability_blocks b set end_date=e.requested_return_date,
 end_time=e.requested_return_time,updated_at=now()
from public.rental_extension_requests e
where b.block_type='extension_hold' and b.active and e.status='approved_pending_payment'
 and b.notes like '%[EXTENSION_REQUEST='||e.id::text||']%';
-- Accept both deployed clients during the rolling release; existing signed records
-- are immutable. The follow-up migration retires the old version after rollout.
do $$ declare d text; begin
 d:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 d:=replace(d, 'new.agreement_version is distinct from ''rentmect-master-v2026-10-23-unreturned-keys-r1''',
  '(new.agreement_version is null or new.agreement_version not in (''rentmect-master-v2026-10-23-unreturned-keys-r1'',''rentmect-master-v2026-11-13-admin-return-r1''))');
 execute d;
end $$;
-- Existing queued emails render the current template at delivery time.
update public.email_templates set
 html_body=replace(replace(replace(html_body,
  'If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review.',
  'Please return the vehicle by the agreed time or contact Rent Me CT to request an extension. No late fee or additional rental day is charged automatically. Extensions and additional charges require explicit approval.'),
  'One additional full rental day plus a $25 late-return fee will be prepared for admin review.',
  'No late fee or additional rental day is charged automatically. Extensions and additional charges require explicit approval.'),
  'is now more than three hours overdue','is now overdue'),
 text_body=replace(replace(replace(text_body,
  'If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review.',
  'Please return the vehicle by the agreed time or contact Rent Me CT to request an extension. No late fee or additional rental day is charged automatically. Extensions and additional charges require explicit approval.'),
  'One additional full rental day plus a $25 late-return fee will be prepared for admin review.',
  'No late fee or additional rental day is charged automatically. Extensions and additional charges require explicit approval.'),
  'is now more than three hours overdue','is now overdue'),
 name=case when template_key='return_overdue_3h_email' then 'Overdue Return Reminder' else name end,
 version=version+1,updated_at=now()
where template_key in ('return_due_previous_morning_email','return_due_3h_email','return_overdue_3h_email');
notify pgrst,'reload schema';
commit;
