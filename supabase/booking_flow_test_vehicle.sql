-- Internal vehicle used only by the footer Booking Preview test lane.
-- It is intentionally absent from cars.html and has no image URLs.

insert into public.vehicles (
  id,
  name,
  brand,
  model,
  vehicle_type,
  daily_rate,
  security_deposit,
  status,
  description,
  features,
  image_urls
) values (
  '00000000-0000-4000-8000-000000000015',
  'Booking Flow Test Vehicle',
  'Rent Me CT',
  'Checkout Preview',
  'Internal Test',
  1,
  300,
  'available',
  'Internal test vehicle for the passwordless Booking Preview flow. Do not use for a live rental.',
  array[]::text[],
  array[]::text[]
)
on conflict (id) do update
set
  name = excluded.name,
  brand = excluded.brand,
  model = excluded.model,
  vehicle_type = excluded.vehicle_type,
  daily_rate = excluded.daily_rate,
  security_deposit = excluded.security_deposit,
  status = excluded.status,
  description = excluded.description,
  features = excluded.features,
  image_urls = excluded.image_urls;

-- Preview bookings intentionally bypass real fleet overlap and admin-calendar
-- locks. The vehicle id is fixed inside this function so this exception can
-- never be used to bypass availability for a real rental vehicle.
create or replace function public.create_booking_flow_test_rental(
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
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years' then 500
    else coalesce(v_vehicle.security_deposit, 300)
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
    '200 miles/day included; excess mileage $0.35/mile'
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
$$;

revoke all on function public.create_booking_flow_test_rental(date, date, text, text) from public;
grant execute on function public.create_booking_flow_test_rental(date, date, text, text) to authenticated;
