-- Rollback-only verification for the canonical calendar and maintenance locks.
-- Run after 20260725033000_calendar_maintenance_command_center.sql.

begin;

do $$
declare
  v_admin_id uuid;
  v_customer_id uuid;
  v_vehicle_id uuid := gen_random_uuid();
  v_oil_id uuid;
  v_rental_id uuid;
  v_rejected boolean;
  v_calendar_count integer;
begin
  select id into v_admin_id from public.profiles where role = 'admin' order by created_at limit 1;
  select id into v_customer_id from public.profiles
  where coalesce(role, 'client') <> 'admin' and date_of_birth is not null
  order by created_at limit 1;
  if v_admin_id is null then raise exception 'AUDIT SETUP: admin profile required.'; end if;
  if v_customer_id is null then raise exception 'AUDIT SETUP: customer with date of birth required.'; end if;

  insert into public.vehicles (
    id, name, brand, model, vehicle_type, daily_rate, security_deposit,
    status, current_mileage, original_mileage, published
  ) values (
    v_vehicle_id, 'Rollback Ford F350 Maintenance Audit', 'Ford', 'F350',
    'Internal Test', 100, 300, 'available', 1000, 1000, false
  );

  if (select count(*) from public.vehicle_maintenance_schedules where vehicle_id = v_vehicle_id) <> 6 then
    raise exception 'AUDIT FAILED: new vehicle did not receive all six maintenance milestones.';
  end if;

  select id into v_oil_id from public.vehicle_maintenance_schedules
  where vehicle_id = v_vehicle_id and service_type = 'oil_change';
  if not exists (
    select 1 from public.vehicle_maintenance_schedules
    where id = v_oil_id and interval_miles = 5000 and next_due_mileage = 6000
  ) then raise exception 'AUDIT FAILED: Ford F350 oil milestone was not seeded at 5,000 miles.'; end if;

  update public.vehicle_maintenance_schedules
  set active = (service_type = 'oil_change')
  where vehicle_id = v_vehicle_id;

  update public.vehicles set current_mileage = 6000 where id = v_vehicle_id;
  if not exists (
    select 1 from public.vehicles
    where id = v_vehicle_id and maintenance_lock_active and status = 'maintenance'
  ) then raise exception 'AUDIT FAILED: due oil service did not auto-lock the vehicle.'; end if;
  if not exists (
    select 1 from public.admin_notification_events
    where event_type = 'maintenance_due' and metadata ->> 'vehicle_id' = v_vehicle_id::text
  ) then raise exception 'AUDIT FAILED: due maintenance push event was not queued.'; end if;

  v_rejected := false;
  begin
    update public.vehicles set status = 'available' where id = v_vehicle_id;
  exception when others then
    v_rejected := position('locked for required maintenance' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: maintenance lock allowed a direct Available status.'; end if;

  perform set_config('request.jwt.claim.sub', v_admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform public.admin_override_vehicle_maintenance(v_vehicle_id, 'Rollback audit confirms time-limited override enforcement.', 4);
  if not exists (
    select 1 from public.vehicles
    where id = v_vehicle_id and not maintenance_lock_active and status = 'available'
      and maintenance_override_until > now()
  ) then raise exception 'AUDIT FAILED: audited maintenance override was not applied.'; end if;

  update public.vehicles set maintenance_override_until = now() - interval '1 minute' where id = v_vehicle_id;
  perform public.evaluate_vehicle_maintenance(v_vehicle_id);
  if not exists (
    select 1 from public.vehicles where id = v_vehicle_id and maintenance_lock_active and status = 'maintenance'
  ) then raise exception 'AUDIT FAILED: expired override did not restore the maintenance lock.'; end if;

  perform public.admin_complete_vehicle_service(v_oil_id, 6000, current_date, 'Rollback audit oil service');
  if not exists (
    select 1 from public.vehicle_maintenance_schedules
    where id = v_oil_id and next_due_mileage = 11000
  ) then raise exception 'AUDIT FAILED: service completion did not advance the oil milestone.'; end if;
  if not exists (
    select 1 from public.vehicles
    where id = v_vehicle_id and not maintenance_lock_active and status = 'available'
  ) then raise exception 'AUDIT FAILED: completed service did not clear the automatic lock.'; end if;

  -- Isolate the odometer trigger from the separate Stripe Identity trigger.
  -- This DDL is inside the transaction and is undone by the final rollback.
  alter table public.rentals disable trigger rentals_require_identity_before_release;

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, payment_status, deposit_status
  ) values (
    v_customer_id, v_vehicle_id, current_date + 200, current_date + 202,
    '9:00 AM', '9:00 AM', 'documents_needed', 'pending', 'pending'
  ) returning id into v_rental_id;

  v_rejected := false;
  begin
    update public.rentals set status = 'active' where id = v_rental_id;
  exception when others then
    v_rejected := position('Starting mileage is mandatory' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: rental activated without starting mileage.'; end if;

  update public.rentals set status = 'active', starting_mileage = 6000 where id = v_rental_id;
  update public.rentals set status = 'return_initiated' where id = v_rental_id;
  v_rejected := false;
  begin
    update public.rentals set status = 'completed' where id = v_rental_id;
  exception when others then
    v_rejected := position('Ending mileage is mandatory' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: rental completed without ending mileage.'; end if;
  update public.rentals set status = 'completed', ending_mileage = 6100 where id = v_rental_id;

  select count(*) into v_calendar_count
  from public.get_admin_calendar_events(current_date + 199, current_date + 203)
  where id = v_rental_id and event_type = 'rental';
  if v_calendar_count <> 1 then raise exception 'AUDIT FAILED: canonical calendar omitted the rental.'; end if;

  raise notice 'PASS: maintenance auto-lock, push event, override expiry, service completion, odometer gates, and canonical calendar.';
end $$;

rollback;
