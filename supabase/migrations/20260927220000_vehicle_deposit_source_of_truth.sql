begin;

-- Vehicle-specific base deposits are authoritative. Preserve every existing
-- rental, payment, allocation, waiver, and approved amendment.
drop trigger if exists rentals_enforce_age_deposit on public.rentals;
drop function if exists public.enforce_rentmect_age_deposit();

-- The age surcharge is a fixed business policy; rental markup remains editable.
update public.under_25_pricing_settings
set deposit_adjustment_enabled = true,
    deposit_adjustment_type = 'fixed',
    deposit_adjustment_value = 200,
    updated_at = now()
where id = true;
alter table public.under_25_pricing_settings
  add constraint under25_deposit_fixed_200
  check (deposit_adjustment_enabled = true
     and deposit_adjustment_type = 'fixed'
     and deposit_adjustment_value = 200);

CREATE OR REPLACE FUNCTION public.rentmect_calculate_under25_deposit(p_base_deposit numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  select round(greatest(coalesce(p_base_deposit, 0), 0) + 200, 2);
$function$;

CREATE OR REPLACE FUNCTION public.admin_create_manual_rental(p_customer_id uuid, p_vehicle_id uuid, p_pickup_date date, p_return_date date, p_pickup_time text DEFAULT '9:00 AM'::text, p_return_time text DEFAULT '9:00 AM'::text)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      and coalesce(lower(r.status), '') not in ('completed', 'cancelled')
      and r.pickup_date is not null
      and r.return_date is not null
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
    when age((now() at time zone 'America/New_York')::date, v_customer.date_of_birth) < interval '25 years'
      then public.rentmect_calculate_under25_deposit(v_vehicle.security_deposit)
    else round(coalesce(v_vehicle.security_deposit, 0), 2)
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
    '250 miles/day included; excess mileage $0.35/mile',
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
      'security_deposit', v_rental.security_deposit,
      'source', 'admin_portal'
    )
  );

  return v_rental;
end;
$function$;

CREATE OR REPLACE FUNCTION public.convert_website_hold_to_rental(p_booking_id uuid, p_customer_phone text DEFAULT NULL::text)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_booking public.pending_bookings%rowtype;
  v_profile public.profiles%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_rental public.rentals%rowtype;
  v_days integer;
  v_security_deposit numeric;
begin
  if v_user_id is null then raise exception 'You must be signed in.'; end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Checkout hold not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'This checkout hold belongs to another customer.';
  end if;
  if lower(coalesce(v_booking.status, 'pending')) <> 'pending'
     or v_booking.expires_at <= now() then
    update public.pending_bookings
      set status = 'expired', updated_at = now()
      where id = v_booking.id and status = 'pending';
    raise exception 'This 25-minute checkout hold expired. Please start a new booking.';
  end if;
  if v_booking.vehicle_id is null then raise exception 'Choose a vehicle before continuing.'; end if;

  perform pg_advisory_xact_lock(hashtext(v_booking.vehicle_id::text));

  select * into v_profile from public.profiles where id = v_user_id for update;
  if not found or v_profile.date_of_birth is null or v_profile.date_of_birth > current_date then
    raise exception 'Add a valid date of birth before booking.';
  end if;
  if coalesce(v_profile.blocked_customer, false)
     or coalesce(v_profile.customer_status, 'good') = 'blocked' then
    raise exception 'This account is blocked from booking. Please contact Rent Me CT.';
  end if;

  select * into v_vehicle from public.vehicles where id = v_booking.vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if coalesce(lower(v_vehicle.status), 'available') in ('maintenance', 'unavailable', 'inactive') then
    raise exception 'This vehicle is not available for booking.';
  end if;

  v_days := v_booking.return_date - v_booking.pickup_date;
  if v_days < 1 then raise exception 'Return date must be after pickup date.'; end if;
  v_security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years'
      then public.rentmect_calculate_under25_deposit(v_vehicle.security_deposit)
    else round(coalesce(v_vehicle.security_deposit, 0), 2)
  end;

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status,
    deposit_status, mileage_policy, checkout_expires_at, payment_due_at,
    source_pending_booking_id, booking_source
  ) values (
    v_user_id, v_booking.vehicle_id, v_booking.pickup_date, v_booking.return_date,
    v_booking.pickup_time, v_booking.return_time,
    'documents_needed', coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    v_security_deposit, 'pending', 'pending',
    '250 miles/day included; excess mileage $0.35/mile',
    v_booking.expires_at, v_booking.expires_at, v_booking.id, 'website_hold'
  )
  returning * into v_rental;

  update public.pending_bookings
    set user_id = v_user_id,
        customer_email = coalesce(nullif(auth.jwt() ->> 'email', ''), customer_email),
        customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
        status = 'converted',
        updated_at = now()
    where id = v_booking.id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_user_id, v_user_id, 'website_hold_converted',
    jsonb_build_object('pending_booking_id', v_booking.id, 'expires_at', v_booking.expires_at)
  );

  return v_rental;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_rental_with_lock(p_vehicle_id uuid, p_pickup_date date, p_return_date date, p_pickup_time text DEFAULT '9:00 AM'::text, p_return_time text DEFAULT '9:00 AM'::text)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_vehicle public.vehicles%rowtype;
  v_profile public.profiles%rowtype;
  v_days integer;
  v_rental public.rentals%rowtype;
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_turnaround_buffer interval := interval '3 hours';
  v_security_deposit numeric;
begin
  if v_user_id is null then raise exception 'You must be signed in to create a rental.'; end if;
  if p_pickup_date is null or p_return_date is null then raise exception 'Pickup and return dates are required.'; end if;

  select * into v_profile from public.profiles where id = v_user_id for update;
  if not found or v_profile.date_of_birth is null or v_profile.date_of_birth > current_date then
    raise exception 'Add a valid date of birth to your profile before booking.';
  end if;
  if coalesce(v_profile.blocked_customer, false) or coalesce(v_profile.customer_status, 'good') = 'blocked' then
    raise exception 'This account is blocked from booking. Please contact Rent Me CT.';
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
    select 1 from public.rentals rentals
    where rentals.vehicle_id = p_vehicle_id
      and coalesce(lower(rentals.status), '') <> 'cancelled'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + v_turnaround_buffer,
        public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
        public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + v_turnaround_buffer
      )
  ) then
    raise exception 'This vehicle is already booked for that pickup and return time.';
  end if;

  if exists (
    select 1 from public.vehicle_availability_blocks blocks
    where blocks.vehicle_id = p_vehicle_id
      and coalesce(blocks.active, true)
      and coalesce(lower(blocks.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + v_turnaround_buffer,
        public.rentmect_rental_timestamp(blocks.start_date, blocks.start_time),
        public.rentmect_rental_timestamp(blocks.end_date, blocks.end_time)
      )
  ) then
    raise exception 'This vehicle is blocked on the admin calendar during that time.';
  end if;

  v_security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years'
      then public.rentmect_calculate_under25_deposit(v_vehicle.security_deposit)
    else round(coalesce(v_vehicle.security_deposit, 0), 2)
  end;

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status, deposit_status, mileage_policy
  ) values (
    v_user_id, p_vehicle_id, p_pickup_date, p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    'documents_needed', coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    v_security_deposit, 'pending', 'pending',
    '250 miles/day included; excess mileage $0.35/mile'
  ) returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_user_id, v_user_id, 'rental_created',
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'pickup_date', p_pickup_date,
      'return_date', p_return_date,
      'age_tier', case when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years' then 'under_25' else '25_or_older' end,
      'security_deposit', v_rental.security_deposit,
      'source', 'client_portal_admin_calendar_lock'
    )
  );

  return v_rental;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_booking_flow_test_rental(p_pickup_date date, p_return_date date, p_pickup_time text DEFAULT '9:00 AM'::text, p_return_time text DEFAULT '9:00 AM'::text)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_test_vehicle_id constant uuid := '00000000-0000-4000-8000-000000000015';
  v_vehicle public.vehicles%rowtype;
  v_profile public.profiles%rowtype;
  v_days integer;
  v_rental public.rentals%rowtype;
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_security_deposit numeric;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to create a preview rental.';
  end if;
  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;

  select * into v_profile
  from public.profiles
  where id = v_user_id;

  if not found or v_profile.date_of_birth is null or v_profile.date_of_birth > current_date then
    raise exception 'Add a valid date of birth to your profile before continuing.';
  end if;
  if coalesce(v_profile.blocked_customer, false) or coalesce(v_profile.customer_status, 'good') = 'blocked' then
    raise exception 'This account is blocked from booking. Please contact Rent Me CT.';
  end if;

  v_days := p_return_date - p_pickup_date;
  if v_days < 1 then
    raise exception 'Return date must be after pickup date.';
  end if;

  v_pickup_at := public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time);
  v_return_at := public.rentmect_rental_timestamp(p_return_date, p_return_time);
  if v_return_at <= v_pickup_at then
    raise exception 'Return time must be after pickup time.';
  end if;

  select * into v_vehicle
  from public.vehicles
  where id = v_test_vehicle_id;

  if not found then
    raise exception 'Booking preview test vehicle is not installed.';
  end if;

  v_security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years'
      then public.rentmect_calculate_under25_deposit(v_vehicle.security_deposit)
    else round(coalesce(v_vehicle.security_deposit, 0), 2)
  end;

  insert into public.rentals (
    user_id,
    vehicle_id,
    pickup_date,
    return_date,
    pickup_time,
    return_time,
    status,
    rental_total,
    tax_amount,
    security_deposit,
    payment_status,
    deposit_status,
    mileage_policy
  ) values (
    v_user_id,
    v_test_vehicle_id,
    p_pickup_date,
    p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    'documents_needed',
    coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    v_security_deposit,
    'pending',
    'pending',
    '250 miles/day included; excess mileage $0.35/mile'
  ) returning * into v_rental;

  insert into public.rental_audit_events (
    rental_id,
    user_id,
    actor_id,
    event_type,
    event_payload
  ) values (
    v_rental.id,
    v_user_id,
    v_user_id,
    'rental_created',
    jsonb_build_object(
      'vehicle_id', v_test_vehicle_id,
      'pickup_date', p_pickup_date,
      'return_date', p_return_date,
      'source', 'booking_flow_preview'
    )
  );

  return v_rental;
end;
$function$;

-- Fail closed if a legacy creation path still contains the old flat amounts.
do $check$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_create_manual_rental', 'create_rental_with_lock', 'convert_website_hold_to_rental', 'create_booking_flow_test_rental')
      and p.prosrc ~ 'then 500([[:space:]]|$)'
  ) then raise exception 'Legacy flat deposit calculation remains'; end if;
end;
$check$;

commit;
