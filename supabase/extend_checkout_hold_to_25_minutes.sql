-- Extends website checkout holds from 15 minutes to 25 minutes.
-- Run once after passwordless_checkout_hold.sql.

alter table public.pending_bookings
  alter column expires_at set default (now() + interval '25 minutes');

-- Give currently active, standard 15-minute holds the additional ten minutes.
update public.pending_bookings
set expires_at = created_at + interval '25 minutes',
    updated_at = now()
where source = 'website'
  and status = 'pending'
  and expires_at > now()
  and expires_at = created_at + interval '15 minutes';

create or replace function public.create_website_pending_booking(
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text default '9:00 AM',
  p_return_time text default '9:00 AM',
  p_vehicle_id uuid default null,
  p_selected_vehicle_name text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
begin
  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;
  if p_return_date <= p_pickup_date then
    raise exception 'Return date must be after pickup date.';
  end if;

  insert into public.pending_bookings (
    pickup_date, return_date, pickup_time, return_time, vehicle_id,
    selected_vehicle_name, status, source, expires_at
  ) values (
    p_pickup_date,
    p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    p_vehicle_id,
    nullif(trim(p_selected_vehicle_name), ''),
    'pending',
    'website',
    now() + interval '25 minutes'
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$$;

revoke all on function public.create_website_pending_booking(date, date, text, text, uuid, text) from public;
grant execute on function public.create_website_pending_booking(date, date, text, text, uuid, text) to anon, authenticated;

create or replace function public.convert_customer_pending_booking(
  p_booking_id uuid,
  p_vehicle_id uuid default null,
  p_customer_phone text default null
) returns public.pending_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_booking public.pending_bookings%rowtype;
begin
  if v_user_id is null then raise exception 'You must be signed in to convert a booking.'; end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Pending booking not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;
  if v_booking.expires_at <= now() or lower(coalesce(v_booking.status, 'pending')) = 'expired' then
    raise exception 'This 25-minute checkout hold has expired. Please start a new booking.';
  end if;

  update public.pending_bookings
  set user_id = v_user_id,
      customer_email = coalesce(v_email, customer_email),
      customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
      vehicle_id = coalesce(p_vehicle_id, vehicle_id),
      status = 'converted',
      updated_at = now()
  where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.convert_customer_pending_booking(uuid, uuid, text) from public;
grant execute on function public.convert_customer_pending_booking(uuid, uuid, text) to authenticated;
