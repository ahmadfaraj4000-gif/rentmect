-- Run after customer_age_deposit_and_calendar_realtime.sql.
-- Creates a real rental for a customer selected by an authenticated admin.

alter table public.profiles
  add column if not exists drivers_license_number text,
  add column if not exists drivers_license_state text,
  add column if not exists insurance_provider text,
  add column if not exists insurance_policy_number text;

create or replace function public.admin_create_manual_rental(
  p_customer_id uuid,
  p_vehicle_id uuid,
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text default '9:00 AM',
  p_return_time text default '9:00 AM'
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_vehicle public.vehicles%rowtype;
  v_customer public.profiles%rowtype;
  v_days integer;
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_security_deposit numeric;
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Only an admin can create a manual booking.';
  end if;
  if p_customer_id is null then raise exception 'Choose a customer.'; end if;
  if p_vehicle_id is null then raise exception 'Choose a vehicle.'; end if;
  if p_pickup_date is null or p_return_date is null then raise exception 'Pickup and return dates are required.'; end if;

  select * into v_customer from public.profiles where id = p_customer_id for update;
  if not found then raise exception 'Customer not found.'; end if;
  if v_customer.date_of_birth is null or v_customer.date_of_birth > current_date then
    raise exception 'Add a valid date of birth to this customer before booking.';
  end if;
  if coalesce(v_customer.blocked_customer, false) or coalesce(v_customer.customer_status, 'good') = 'blocked' then
    raise exception 'This customer is blocked from booking.';
  end if;

  v_days := p_return_date - p_pickup_date;
  if v_days < 1 then raise exception 'Return date must be after pickup date.'; end if;
  v_pickup_at := public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time);
  v_return_at := public.rentmect_rental_timestamp(p_return_date, p_return_time);
  if v_return_at <= v_pickup_at then raise exception 'Return time must be after pickup time.'; end if;

  perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if coalesce(lower(v_vehicle.status), 'available') in ('maintenance', 'unavailable', 'inactive') then
    raise exception 'This vehicle is not available for booking.';
  end if;

  if exists (
    select 1
    from public.rentals r
    where r.vehicle_id = p_vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) then
    raise exception 'This vehicle is already booked for that pickup and return time.';
  end if;

  if exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = p_vehicle_id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'This vehicle has a calendar block during that time.';
  end if;

  v_security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_customer.date_of_birth) < interval '25 years' then 500
    else 300
  end;

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status,
    deposit_status, mileage_policy, admin_notes
  ) values (
    p_customer_id, p_vehicle_id, p_pickup_date, p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    'documents_needed', coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    v_security_deposit, 'pending', 'pending',
    '200 miles/day included; excess mileage $0.35/mile',
    'Created manually in the admin portal'
  ) returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, p_customer_id, v_admin_id, 'manual_rental_created',
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'pickup_date', p_pickup_date,
      'return_date', p_return_date,
      'age_tier', case when age((now() at time zone 'America/New_York')::date, v_customer.date_of_birth) < interval '25 years' then 'under_25' else '25_or_older' end,
      'security_deposit', v_security_deposit,
      'source', 'admin_portal'
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.admin_create_manual_rental(uuid, uuid, date, date, text, text) from public;
grant execute on function public.admin_create_manual_rental(uuid, uuid, date, date, text, text) to authenticated;
