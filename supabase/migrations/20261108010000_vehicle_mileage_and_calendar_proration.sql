begin;
-- Keep odometer readings with the physical vehicle assignment, not just the trip.
alter table public.rental_vehicle_assignments
 add column starting_mileage integer check (starting_mileage between 0 and 9999999),
 add column ending_mileage integer check (ending_mileage between 0 and 9999999),
 add constraint assignment_mileage_order check (ending_mileage >= starting_mileage);
alter table public.rentals add column prior_vehicle_miles integer not null default 0 check(prior_vehicle_miles>=0),
 add column mileage_history_complete boolean not null default true;
alter table public.rentals alter column miles_driven set expression as
 (case when mileage_history_complete and starting_mileage is not null and ending_mileage is not null
 then prior_vehicle_miles + ending_mileage - starting_mileage else null end);
-- Preserve the original pickup reading on the first actual possession interval.
-- Never infer a replacement pickup reading from the fleet's current odometer.
update public.rental_vehicle_assignments a set starting_mileage=r.starting_mileage
from public.rentals r where r.id=a.rental_id and r.starting_mileage is not null
and a.id=(select x.id from public.rental_vehicle_assignments x where x.rental_id=r.id
 and x.assigned_until>x.assigned_from order by x.assigned_from,x.created_at,x.id limit 1);

create or replace function public.rentmect_pricing_fraction(p_start timestamptz,p_end timestamptz,p_at timestamptz)
returns numeric language sql immutable set search_path=public as $$
 select greatest(0,least(1,case
 when (p_end at time zone 'America/New_York')>(p_start at time zone 'America/New_York') then
 extract(epoch from ((p_at at time zone 'America/New_York')-(p_start at time zone 'America/New_York')))
 / nullif(extract(epoch from ((p_end at time zone 'America/New_York')-(p_start at time zone 'America/New_York'))),0)
 else extract(epoch from p_at-p_start)/nullif(extract(epoch from p_end-p_start),0) end));
$$;

alter function public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text)
 rename to admin_apply_vehicle_swap_before_mileage;
revoke all on function public.admin_apply_vehicle_swap_before_mileage(uuid,uuid,timestamptz,text,text,numeric,uuid,text) from public,anon,authenticated;
create function public.admin_apply_vehicle_swap(p_rental_id uuid,p_vehicle_id uuid,p_effective_at timestamptz,
 p_swap_kind text,p_reason text,p_daily_rate numeric,p_idempotency_key uuid,p_expected_revision text,
 p_outgoing_mileage integer default null,p_incoming_mileage integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; a rental_vehicle_assignments%rowtype; prior rental_vehicle_swaps%rowtype;
 req jsonb; result jsonb; baseline integer; incoming integer; outgoing integer; complete boolean; distance integer;
begin
 if auth.uid() is null or not coalesce(rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
 if p_idempotency_key is null then raise exception 'Idempotency key is required.'; end if;
 select * into strict r from rentals where id=p_rental_id for update;
 req:=jsonb_build_object('rental_id',p_rental_id,'vehicle_id',p_vehicle_id,'effective_at',p_effective_at,
 'swap_kind',p_swap_kind,'reason',trim(p_reason),'daily_rate',p_daily_rate,
 'outgoing_mileage',p_outgoing_mileage,'incoming_mileage',p_incoming_mileage);
 select * into prior from rental_vehicle_swaps where id=p_idempotency_key;
 if found then
  if prior.request is distinct from req then raise exception 'Idempotency key already used for a different swap.'; end if;
  return prior.financial_effect||jsonb_build_object('idempotent_replay',true);
 end if;
 if p_outgoing_mileage is null or p_incoming_mileage is null then
  raise exception 'Record both vehicles’ odometer readings before confirming the swap. Refresh the page if those fields are missing.'; end if;
 if p_outgoing_mileage not between 0 and 9999999 or p_incoming_mileage not between 0 and 9999999 then
  raise exception 'Odometer readings must be whole numbers from 0 to 9999999.'; end if;
 perform 1 from vehicles where id in(r.vehicle_id,p_vehicle_id) order by id for update;
 select current_mileage into incoming from vehicles where id=p_vehicle_id;
 select current_mileage into outgoing from vehicles where id=r.vehicle_id;
 select * into a from rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from order by assigned_from desc,created_at desc,id desc limit 1 for update;
 baseline:=a.starting_mileage;
 if baseline is null and not exists(select 1 from rental_vehicle_assignments where rental_id=r.id and vehicle_id<>r.vehicle_id and assigned_until>assigned_from) then baseline:=r.starting_mileage; end if;
 if p_outgoing_mileage<greatest(coalesce(baseline,0),coalesce(outgoing,0)) then raise exception 'Outgoing mileage cannot be below the recorded mileage for that vehicle.'; end if;
 if p_incoming_mileage<coalesce(incoming,0) then raise exception 'Replacement pickup mileage cannot be below that vehicle’s recorded odometer.'; end if;
 result:=admin_apply_vehicle_swap_before_mileage(p_rental_id,p_vehicle_id,p_effective_at,p_swap_kind,p_reason,p_daily_rate,p_idempotency_key,p_expected_revision);
 update rental_vehicle_assignments set starting_mileage=baseline,ending_mileage=p_outgoing_mileage where id=a.id;
 update rental_vehicle_assignments set starting_mileage=p_incoming_mileage where swap_id=p_idempotency_key;
 select coalesce(bool_and(starting_mileage is not null and ending_mileage is not null),true),
 coalesce(sum(ending_mileage-starting_mileage),0)::integer into complete,distance
 from rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from and swap_id is distinct from p_idempotency_key;
 update rentals set starting_mileage=p_incoming_mileage,ending_mileage=null,
 prior_vehicle_miles=distance,mileage_history_complete=complete where id=r.id;
 update vehicles set current_mileage=p_outgoing_mileage where id=r.vehicle_id;
 update vehicles set current_mileage=p_incoming_mileage where id=p_vehicle_id;
 result:=result||jsonb_build_object('outgoing_mileage',p_outgoing_mileage,'incoming_mileage',p_incoming_mileage,'mileage_history_complete',complete);
 update rental_vehicle_swaps set request=req,financial_effect=result where id=p_idempotency_key;
 insert into rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
 values(r.id,r.user_id,auth.uid(),'vehicle_swap_mileage_recorded',req||jsonb_build_object('prior_vehicle_miles',distance,'mileage_history_complete',complete));
 return result;
end $$;
revoke all on function public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text,integer,integer) from public,anon;
grant execute on function public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text,integer,integer) to authenticated;

CREATE OR REPLACE FUNCTION public.enforce_rental_odometer_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_status text := lower(coalesce(new.status, ''));
begin
  if v_status in ('active', 'overdue', 'return_initiated')
     and new.starting_mileage is null then
    raise exception 'Starting mileage is mandatory before a vehicle can leave the lot.';
  end if;
  if v_status = 'active'
     and (tg_op = 'INSERT' or lower(coalesce(old.status, '')) <> 'active')
     and exists (
       select 1
       from public.vehicles vehicle
       join public.vehicle_maintenance_schedules schedule on schedule.vehicle_id = vehicle.id
       where vehicle.id = new.vehicle_id
         and schedule.active and schedule.lock_when_due
         and not (vehicle.maintenance_override_until is not null and vehicle.maintenance_override_until > now())
         and (
           (schedule.next_due_mileage is not null and new.starting_mileage >= schedule.next_due_mileage)
           or (schedule.next_due_at is not null and current_date >= schedule.next_due_at)
         )
     ) then
    raise exception 'Required maintenance is due at this odometer reading. Complete service or create an audited override before releasing the vehicle.';
  end if;
  if v_status = 'completed' and new.ending_mileage is null and not (
    exists(select 1 from public.rental_return_inspections i where i.rental_id=new.id
      and i.created_at=new.inspection_completed_at
      and i.mileage_override and i.fuel_checked and i.damage_checked and length(trim(i.notes))>=10
      and ((auth.uid() is not null and coalesce(public.rentmect_has_permission('rental.return'),false)
        and i.admin_id=auth.uid() and new.inspection_completed_at=transaction_timestamp())
        or (tg_op='UPDATE' and old.status='completed' and old.ending_mileage is null
          and new.inspection_completed_at=old.inspection_completed_at)))
  ) then
    raise exception 'Ending mileage is mandatory before a returned vehicle can be closed.';
  end if;
  if new.starting_mileage is not null and new.ending_mileage is not null
     and new.ending_mileage < new.starting_mileage then
    raise exception 'Ending mileage cannot be below starting mileage.';
  end if;
  return new;
end;
$function$
;

drop function public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric);
CREATE OR REPLACE FUNCTION public.admin_preview_vehicle_swap(p_rental_id uuid, p_vehicle_id uuid, p_effective_at timestamp with time zone, p_swap_kind text, p_reason text, p_daily_rate numeric DEFAULT NULL::numeric, p_outgoing_mileage integer DEFAULT NULL, p_incoming_mileage integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.rentals%rowtype; a public.rental_vehicle_assignments%rowtype; p record;
  until_at timestamptz; delta numeric:=0; tax_delta numeric:=0; units numeric; part numeric; change numeric;
  periods jsonb:='[]'; invoice numeric; paid numeric; additional numeric; fingerprint text;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then
    raise exception 'Rental editing permission is required.'; end if;
  if p_swap_kind is null or p_swap_kind not in ('customer_request','emergency','maintenance')
    or length(trim(coalesce(p_reason,'')))<10 or p_effective_at is null then
    raise exception 'A swap type, effective time, and specific reason are required.'; end if;
  select * into strict r from public.rentals where id=p_rental_id for update;
  if p_outgoing_mileage is not null or p_incoming_mileage is not null then
    if p_outgoing_mileage is null or p_incoming_mileage is null then raise exception 'Record both vehicles’ odometer readings before confirming the swap.'; end if;
    if p_outgoing_mileage not between 0 and 9999999 or p_incoming_mileage not between 0 and 9999999 then raise exception 'Odometer readings must be whole numbers from 0 to 9999999.'; end if;
    if p_outgoing_mileage<greatest(coalesce((select starting_mileage from rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from order by assigned_from desc,created_at desc,id desc limit 1),
      case when not exists(select 1 from rental_vehicle_assignments where rental_id=r.id and vehicle_id<>r.vehicle_id and assigned_until>assigned_from) then r.starting_mileage else 0 end,0),
      coalesce((select current_mileage from vehicles where id=r.vehicle_id),0)) then raise exception 'Outgoing mileage cannot be below the recorded mileage for that vehicle.'; end if;
    if p_incoming_mileage<coalesce((select current_mileage from vehicles where id=p_vehicle_id),0) then raise exception 'Replacement pickup mileage cannot be below that vehicle’s recorded odometer.'; end if;
  end if;
  if r.status not in ('active','rented','overdue','return_initiated','completed') then raise exception 'Only a started rental can be swapped.'; end if;
  until_at:=public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York';
  if p_effective_at<=(public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')
    or p_effective_at>=until_at or p_effective_at>now() then raise exception 'Effective time must be inside the rental and cannot be in the future.'; end if;
  select * into a from public.rental_vehicle_assignments where rental_id=r.id order by assigned_from desc limit 1;
  if a.id is null or p_effective_at<=a.assigned_from or p_effective_at>=a.assigned_until or a.vehicle_id=p_vehicle_id then
    raise exception 'Choose a different vehicle and a time after the latest assignment began.'; end if;
  if not exists(select 1 from public.vehicles where id=p_vehicle_id and coalesce(is_active,true)
    and not coalesce(maintenance_lock_active,false) and lower(coalesce(status,'available')) not in ('maintenance','unavailable','inactive','retired')
    and id<>'00000000-0000-4000-8000-000000000015'::uuid) then raise exception 'Replacement vehicle is unavailable.'; end if;
  if p_swap_kind='customer_request' and (p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000) then
    raise exception 'Enter the agreed replacement daily rate.'; end if;
  if p_swap_kind in ('emergency','maintenance') and p_daily_rate is not null then
    raise exception 'Emergency and maintenance replacements preserve all booked pricing periods.'; end if;
  if exists(select 1 from public.rental_extension_requests where rental_id=r.id and status in ('pending','approved_pending_payment')) then
    raise exception 'Resolve the pending or approved unpaid extension before changing its vehicle.'; end if;
  perform public.rentmect_assert_swap_available(r.id,p_vehicle_id,p_effective_at,until_at);
  for p in select * from jsonb_populate_recordset(null::public.rental_pricing_periods,public.rentmect_pricing_snapshot(r.id)) order by starts_at loop
    if p.ends_at>p_effective_at then
      part:=1-public.rentmect_pricing_fraction(p.starts_at,p.ends_at,greatest(p.starts_at,p_effective_at));
      units:=p.billing_units*part;
      change:=case when p_swap_kind='customer_request' then round((p_daily_rate-p.daily_rate)*units*(1+p.markup_percentage/100),2) else 0 end;
      if round(p.rental_amount*part,2)+change<0 then raise exception 'This rate would exceed the remaining discounted charge; use an explicit credit correction.'; end if;
      delta:=delta+change; tax_delta:=tax_delta+round(change*0.0635,2);
      periods:=periods||jsonb_build_array(jsonb_build_object('from',greatest(p.starts_at,p_effective_at),'until',p.ends_at,
        'old_rate',p.daily_rate,'new_rate',case when p_swap_kind='customer_request' then p_daily_rate else p.daily_rate end,
        'billing_units',units,'rental_delta',change,'tax_delta',round(change*0.0635,2)));
    end if;
  end loop;
  invoice:=public.rentmect_rental_invoice_total(r.id); paid:=public.rentmect_rental_net_paid_amount(r.id);
  select coalesce(sum(total_amount),0) into additional from public.rental_charge_items where rental_id=r.id
    and not coalesce(included_in_initial_payment,false) and charge_type not in ('rental_amendment','rental_installment')
    and status in ('pending','checkout_open','failed');
  fingerprint:=
    md5(jsonb_build_object(
      'rental', (to_jsonb(r)-array['updated_at','stripe_checkout_session_id','stripe_payment_intent_id','payment_provider','payment_amount_cents'])
        ||jsonb_build_object('captured_amount_cents',case when r.paid_at is not null then r.payment_amount_cents else 0 end),
      'request',jsonb_build_object('vehicle_id',p_vehicle_id,'effective_at',p_effective_at,
        'swap_kind',p_swap_kind,'reason',trim(p_reason),'daily_rate',p_daily_rate),
      'assignments',(select jsonb_agg(assignment_row order by assignment_row.assigned_from,assignment_row.id)
        from public.rental_vehicle_assignments assignment_row where assignment_row.rental_id=r.id),
      'periods',public.rentmect_pricing_snapshot(r.id),'net_paid',paid,'additional_balance',additional
    )::text)
  ;
  return jsonb_build_object('rental_id',r.id,'effective_at',p_effective_at,'recorded_at',now(),'periods',periods,
    'invoice_before',invoice,'invoice_after',invoice+delta+tax_delta,'rental_delta',delta,'tax_delta',tax_delta,
    'total_delta',delta+tax_delta,'previous_balance',greatest(0,invoice-paid)+additional,'balance_due',greatest(0,invoice+delta+tax_delta-paid)+additional,
    'credit_due',greatest(0,paid-invoice-delta-tax_delta),'deposit_held',coalesce(r.deposit_held_amount,0),
    'requires_customer_resign',coalesce(r.agreement_signed,false),'revision',fingerprint,'pricing_preserved',p_swap_kind<>'customer_request');
end; $function$
;
revoke all on function public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,integer,integer) from public,anon;
grant execute on function public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,integer,integer) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_inspect_and_complete_rental_return(p_rental_id uuid, p_ending_mileage integer, p_mileage_checked boolean, p_fuel_checked boolean, p_damage_checked boolean, p_damage_found boolean, p_deposit_decision text, p_notes text DEFAULT NULL::text, p_vehicle_disposition text DEFAULT 'available'::text, p_mileage_override boolean DEFAULT false)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_previous_status text;
  a public.rental_vehicle_assignments%rowtype; baseline integer; distance integer; complete boolean;
begin
  if v_admin_id is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('rental.return'),false) then
    raise exception 'Admin access is required.';
  end if;

  if not coalesce(p_mileage_override, false)
     and (p_ending_mileage is null or p_ending_mileage < 0) then
    raise exception 'Ending mileage is required unless the admin mileage override is enabled.';
  end if;

  if not coalesce(p_mileage_override, false)
     and not coalesce(p_mileage_checked, false) then
    raise exception 'Verify the ending mileage or use the explicit admin mileage override.';
  end if;

  if not coalesce(p_fuel_checked, false)
     or not coalesce(p_damage_checked, false) then
    raise exception 'Fuel and vehicle condition must be inspected before the vehicle is released.';
  end if;

  if p_deposit_decision is null or p_deposit_decision not in ('release', 'hold') then
    raise exception 'Choose release or hold for the deposit.';
  end if;

  if p_vehicle_disposition is null or p_vehicle_disposition not in ('available', 'maintenance', 'unavailable') then
    raise exception 'Choose a valid vehicle disposition.';
  end if;

  if p_damage_found and (p_deposit_decision <> 'hold' or p_vehicle_disposition = 'available') then
    raise exception 'Damage requires a held deposit and a maintenance/unavailable vehicle disposition.';
  end if;

  if (p_damage_found or p_deposit_decision = 'hold')
     and length(trim(coalesce(p_notes, ''))) < 5 then
    raise exception 'Add inspection notes explaining the damage or deposit hold.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  v_previous_status := lower(coalesce(v_rental.status, ''));
  if v_previous_status not in ('active', 'rented', 'overdue', 'return_initiated') then
    raise exception 'Only an active, overdue, or return-initiated rental can be closed through return inspection.';
  end if;

  select * into a from public.rental_vehicle_assignments where rental_id=v_rental.id
   and assigned_until>assigned_from order by assigned_from desc,created_at desc,id desc limit 1 for update;
  baseline:=a.starting_mileage;
  if baseline is null and not exists(select 1 from public.rental_vehicle_assignments
   where rental_id=v_rental.id and vehicle_id<>v_rental.vehicle_id and assigned_until>assigned_from) then baseline:=v_rental.starting_mileage; end if;
  if (p_mileage_override or baseline is null) and length(trim(coalesce(p_notes,'')))<10 then
   raise exception 'Explain the missing mileage or override in at least 10 characters.'; end if;
  if not coalesce(p_mileage_override,false) and (p_ending_mileage>9999999 or p_ending_mileage<coalesce((select current_mileage from public.vehicles where id=v_rental.vehicle_id),0)) then
   raise exception 'Return mileage cannot be below the vehicle odometer or above 9999999.'; end if;
  if not coalesce(p_mileage_override,false) and p_ending_mileage is not null
     and baseline is not null and p_ending_mileage < baseline then
    raise exception 'Ending mileage cannot be below starting mileage.';
  end if;

  insert into public.rental_return_inspections (
    rental_id, user_id, admin_id, mileage_checked, ending_mileage,
    fuel_checked, damage_checked, damage_found, deposit_decision,
    notes, skipped, mileage_override
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id,
    not coalesce(p_mileage_override, false),
    case when p_mileage_override then null else p_ending_mileage end,
    true, true, p_damage_found, p_deposit_decision,
    nullif(trim(p_notes), ''),
    coalesce(p_mileage_override, false),
    coalesce(p_mileage_override, false)
  );

  update public.rental_vehicle_assignments set starting_mileage=baseline,
   ending_mileage=case when p_mileage_override then null else p_ending_mileage end where id=a.id;
  select coalesce(bool_and(starting_mileage is not null and ending_mileage is not null),true),
   coalesce(sum(ending_mileage-starting_mileage),0)::integer into complete,distance
   from public.rental_vehicle_assignments where rental_id=v_rental.id and assigned_until>assigned_from and id is distinct from a.id;
  update public.rentals
    set starting_mileage=baseline, prior_vehicle_miles=distance,
        mileage_history_complete=complete and baseline is not null and not coalesce(p_mileage_override,false),
        status = 'completed',
        ending_mileage = case
          when p_mileage_override then null
          else p_ending_mileage
        end,
        inspection_completed_at = now(),
        deposit_status = case
          when p_deposit_decision = 'hold' then 'held'
          else deposit_status
        end,
        deposit_release_due_at = case
          when p_deposit_decision = 'hold' then null
          else deposit_release_due_at
        end,
        deposit_release_reason = case
          when p_deposit_decision = 'hold' then 'Held after return inspection: ' || trim(p_notes)
          else deposit_release_reason
        end,
        updated_at = now()
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = p_vehicle_disposition,
        current_mileage = case
          when p_mileage_override then current_mileage
          else p_ending_mileage
        end
    where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_return_inspection_completed',
    jsonb_build_object(
      'previous_status', v_previous_status,
      'ending_mileage', case when p_mileage_override then null else p_ending_mileage end,
      'mileage_override', coalesce(p_mileage_override, false),
      'maintenance_tracking_warning', case
        when p_mileage_override then 'Returning mileage must be recorded as soon as possible.'
        else null
      end,
      'damage_found', p_damage_found,
      'deposit_decision', p_deposit_decision,
      'vehicle_disposition', p_vehicle_disposition,
      'notes', nullif(trim(p_notes), '')
    )
  );

  return v_rental;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_rental_detail(p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare r public.rentals%rowtype; result jsonb;
begin
  if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
    raise exception 'Rental access is required.' using errcode='42501'; end if;
  select * into r from public.rentals where id=p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  select jsonb_build_object(
    'rental',to_jsonb(r)||jsonb_build_object('return_starting_mileage',case
 when exists(select 1 from public.rental_vehicle_assignments where rental_id=r.id and vehicle_id<>r.vehicle_id and assigned_until>assigned_from)
 then (select starting_mileage from public.rental_vehicle_assignments where rental_id=r.id and assigned_until>assigned_from order by assigned_from desc,created_at desc,id desc limit 1)
 else r.starting_mileage end)||public.staff_payment_annotation('rental',r.id)||jsonb_build_object('pending_external_payment_id',(select id from public.external_payment_receipts where rental_id=r.id and status='pending'))||jsonb_build_object('profiles',(select to_jsonb(p) from public.profiles p where p.id=r.user_id),
      'vehicles',(select to_jsonb(v) from public.vehicles v where v.id=r.vehicle_id)),
    'documents',coalesce((select jsonb_agg(d order by d.created_at desc,d.id desc) from public.rental_documents d where d.rental_id=r.id or
      (d.user_id=r.user_id and d.document_type='license')),'[]'),
    'reports',coalesce((select jsonb_agg(x order by x.created_at desc,x.id desc) from public.vehicle_reports x where x.rental_id=r.id),'[]'),
    'extensions',coalesce((select jsonb_agg(to_jsonb(e)||public.staff_payment_annotation('extension',e.id) order by e.created_at desc) from public.rental_extension_requests e where e.rental_id=r.id),'[]'),
    'exceptions',coalesce((select jsonb_agg(e) from public.rental_emergency_exceptions e where e.rental_id=r.id),'[]'),
    'steps',coalesce((select jsonb_agg(s) from public.rental_step_completions s where s.rental_id=r.id),'[]'),
    'deposits',coalesce((select jsonb_agg(d) from public.rental_deposit_allocations d where d.holder_rental_id=r.id),'[]'),
    'payments',coalesce((select jsonb_agg(to_jsonb(p)||public.staff_payment_annotation('payment',p.id)) from public.rental_payments p where p.rental_id=r.id),'[]'),
    'refunds',coalesce((select jsonb_agg(f) from public.rental_payment_refunds f where f.rental_id=r.id),'[]'),
    'charges',coalesce((select jsonb_agg(to_jsonb(c)||public.staff_payment_annotation('rental_charge',c.id)||jsonb_build_object('payment_notes',coalesce((select notes from public.external_payment_receipts where id=c.payment_receipt_id),(public.staff_payment_annotation('rental_charge',c.id)->>'payment_notes')),'receipt_status',(select status from public.external_payment_receipts where id=c.payment_receipt_id))) from public.rental_charge_items c where c.rental_id=r.id),'[]'),
    'externalActions',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('recorded_by_profile',
      (select jsonb_build_object('id',p.id,'full_name',p.full_name,'email',p.email) from public.profiles p where p.id=a.created_by)))
      from public.rental_external_payment_actions a where a.rental_id=r.id),'[]')
  ) into result;
  return result;
end; $function$
;

notify pgrst, 'reload schema';
commit;
