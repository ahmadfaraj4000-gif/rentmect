-- Qualify pending-booking columns that share names with function output fields.

create or replace function public.create_rate_limited_website_booking_hold(
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text,
  p_return_time text,
  p_vehicle_id uuid,
  p_ip_hash text,
  p_device_hash text
) returns table (
  accepted boolean,
  booking_id uuid,
  abandon_token uuid,
  expires_at timestamptz,
  error_code text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id bigint;
  v_vehicle public.vehicles%rowtype;
  v_booking public.pending_bookings%rowtype;
  v_pickup_time text := coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM');
  v_return_time text := coalesce(nullif(trim(p_return_time), ''), '9:00 AM');
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_local_today date := (now() at time zone 'America/New_York')::date;
  v_ip_attempts_15m integer;
  v_device_attempts_15m integer;
  v_ip_attempts_day integer;
  v_device_attempts_day integer;
  v_ip_active_holds integer;
  v_device_active_holds integer;
begin
  if p_ip_hash !~ '^[0-9a-f]{64}$' or p_device_hash !~ '^[0-9a-f]{64}$' then
    return query select false, null::uuid, null::uuid, null::timestamptz, 'invalid_request'::text;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('hold-ip:' || p_ip_hash));
  perform pg_advisory_xact_lock(hashtext('hold-device:' || p_device_hash));

  delete from public.website_booking_hold_security_events event
  where event.created_at < now() - interval '7 days';

  insert into public.website_booking_hold_security_events (
    ip_hash, device_hash, vehicle_id, outcome
  ) values (
    p_ip_hash, p_device_hash, p_vehicle_id, 'attempt'
  ) returning id into v_event_id;

  select
    count(*) filter (where event.ip_hash = p_ip_hash and event.created_at >= now() - interval '15 minutes'),
    count(*) filter (where event.device_hash = p_device_hash and event.created_at >= now() - interval '15 minutes'),
    count(*) filter (where event.ip_hash = p_ip_hash and event.created_at >= now() - interval '1 day'),
    count(*) filter (where event.device_hash = p_device_hash and event.created_at >= now() - interval '1 day')
  into v_ip_attempts_15m, v_device_attempts_15m, v_ip_attempts_day, v_device_attempts_day
  from public.website_booking_hold_security_events event;

  select count(*) into v_ip_active_holds
  from public.pending_bookings booking
  where booking.hold_ip_hash = p_ip_hash
    and lower(coalesce(booking.status, 'pending')) = 'pending'
    and booking.expires_at > now();

  select count(*) into v_device_active_holds
  from public.pending_bookings booking
  where booking.hold_device_hash = p_device_hash
    and lower(coalesce(booking.status, 'pending')) = 'pending'
    and booking.expires_at > now();

  if v_ip_attempts_15m > 12
     or v_device_attempts_15m > 8
     or v_ip_attempts_day > 40
     or v_device_attempts_day > 24
     or v_ip_active_holds >= 6
     or v_device_active_holds >= 3 then
    update public.website_booking_hold_security_events event
    set outcome = 'rate_limited'
    where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'rate_limited'::text;
    return;
  end if;

  if p_vehicle_id is null
     or p_pickup_date is null
     or p_return_date is null
     or p_pickup_date < v_local_today
     or p_pickup_date > v_local_today + 365
     or p_return_date > p_pickup_date + 180 then
    update public.website_booking_hold_security_events event set outcome = 'invalid' where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'invalid_request'::text;
    return;
  end if;

  begin
    v_pickup_at := public.rentmect_rental_timestamp(p_pickup_date, v_pickup_time);
    v_return_at := public.rentmect_rental_timestamp(p_return_date, v_return_time);
  exception when others then
    update public.website_booking_hold_security_events event set outcome = 'invalid' where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'invalid_request'::text;
    return;
  end;

  if v_return_at <= v_pickup_at then
    update public.website_booking_hold_security_events event set outcome = 'invalid' where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'invalid_request'::text;
    return;
  end if;

  select * into v_vehicle
  from public.vehicles vehicle
  where vehicle.id = p_vehicle_id
    and coalesce(vehicle.published, false)
    and coalesce(vehicle.is_active, true)
    and coalesce(lower(vehicle.status), 'available') not in ('maintenance', 'unavailable', 'inactive');

  if not found then
    update public.website_booking_hold_security_events event set outcome = 'unavailable' where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'vehicle_unavailable'::text;
    return;
  end if;

  begin
    insert into public.pending_bookings (
      pickup_date,
      return_date,
      pickup_time,
      return_time,
      vehicle_id,
      selected_vehicle_name,
      status,
      source,
      expires_at,
      hold_ip_hash,
      hold_device_hash
    ) values (
      p_pickup_date,
      p_return_date,
      v_pickup_time,
      v_return_time,
      v_vehicle.id,
      v_vehicle.name,
      'pending',
      'website',
      now() + interval '25 minutes',
      p_ip_hash,
      p_device_hash
    ) returning * into v_booking;
  exception when others then
    update public.website_booking_hold_security_events event set outcome = 'unavailable' where event.id = v_event_id;
    return query select false, null::uuid, null::uuid, null::timestamptz, 'vehicle_unavailable'::text;
    return;
  end;

  update public.website_booking_hold_security_events event set outcome = 'created' where event.id = v_event_id;
  return query select true, v_booking.id, v_booking.abandon_token, v_booking.expires_at, null::text;
end;
$$;

revoke all on function public.create_rate_limited_website_booking_hold(date, date, text, text, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.create_rate_limited_website_booking_hold(date, date, text, text, uuid, text, text)
  to service_role;
