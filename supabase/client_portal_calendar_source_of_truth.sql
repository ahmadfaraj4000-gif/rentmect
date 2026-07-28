-- Makes rentals plus active admin calendar blocks the client portal's availability source of truth.
-- Run after admin_pricing_settings.sql, production_rls_policies.sql, and
-- customer_age_deposit_and_calendar_realtime.sql.

drop function if exists public.get_vehicle_booking_blocks();

create function public.get_vehicle_booking_blocks()
returns table (
  id uuid,
  vehicle_id uuid,
  pickup_date date,
  return_date date,
  pickup_time text,
  return_time text,
  status text,
  payment_status text,
  deposit_status text,
  paid_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    rentals.id,
    rentals.vehicle_id,
    rentals.pickup_date,
    rentals.return_date,
    rentals.pickup_time,
    rentals.return_time,
    rentals.status,
    rentals.payment_status,
    rentals.deposit_status,
    rentals.paid_at
  from public.rentals
  where coalesce(lower(rentals.status), '') <> 'cancelled'
    and rentals.vehicle_id is not null
    and rentals.pickup_date is not null
    and rentals.return_date is not null

  union all

  select
    blocks.id,
    blocks.vehicle_id,
    blocks.start_date,
    blocks.end_date,
    blocks.start_time,
    blocks.end_time,
    'calendar_block'::text,
    null::text,
    null::text,
    null::timestamptz
  from public.vehicle_availability_blocks blocks
  where coalesce(blocks.active, true)
    and coalesce(lower(blocks.block_type), 'unavailable') <> 'available';
$$;

grant execute on function public.get_vehicle_booking_blocks() to anon, authenticated;

-- Public fleet fallback used only when Wheelbase cannot return a clear answer.
-- It mirrors the same rental and admin-calendar locks enforced at checkout.
create or replace function public.get_admin_calendar_fleet_availability(
  p_pickup_date date,
  p_pickup_time text,
  p_return_date date,
  p_return_time text
)
returns table (
  vehicle_id uuid,
  available boolean,
  reason text
)
language sql
security definer
set search_path = public
as $$
  with requested as (
    select
      public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time) as pickup_at,
      public.rentmect_rental_timestamp(p_return_date, p_return_time) as return_at,
      interval '3 hours' as turnaround_buffer
  )
  select
    vehicles.id,
    not (
      coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
      or exists (
        select 1
        from public.rentals rentals
        cross join requested
        where rentals.vehicle_id = vehicles.id
          and coalesce(lower(rentals.status), '') <> 'cancelled'
          and rentals.pickup_date is not null
          and rentals.return_date is not null
          and public.rentmect_periods_overlap(
            requested.pickup_at,
            requested.return_at + requested.turnaround_buffer,
            public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
            public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + requested.turnaround_buffer
          )
      )
      or exists (
        select 1
        from public.vehicle_availability_blocks blocks
        cross join requested
        where blocks.vehicle_id = vehicles.id
          and coalesce(blocks.active, true)
          and coalesce(lower(blocks.block_type), 'unavailable') <> 'available'
          and public.rentmect_periods_overlap(
            requested.pickup_at,
            requested.return_at + requested.turnaround_buffer,
            public.rentmect_rental_timestamp(blocks.start_date, blocks.start_time),
            public.rentmect_rental_timestamp(blocks.end_date, blocks.end_time)
          )
      )
    ) as available,
    case
      when coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
        then 'Vehicle unavailable'
      when exists (
        select 1
        from public.vehicle_availability_blocks blocks
        cross join requested
        where blocks.vehicle_id = vehicles.id
          and coalesce(blocks.active, true)
          and coalesce(lower(blocks.block_type), 'unavailable') <> 'available'
          and public.rentmect_periods_overlap(
            requested.pickup_at,
            requested.return_at + requested.turnaround_buffer,
            public.rentmect_rental_timestamp(blocks.start_date, blocks.start_time),
            public.rentmect_rental_timestamp(blocks.end_date, blocks.end_time)
          )
      ) then 'Blocked on the Rent Me CT calendar'
      when exists (
        select 1
        from public.rentals rentals
        cross join requested
        where rentals.vehicle_id = vehicles.id
          and coalesce(lower(rentals.status), '') <> 'cancelled'
          and rentals.pickup_date is not null
          and rentals.return_date is not null
          and public.rentmect_periods_overlap(
            requested.pickup_at,
            requested.return_at + requested.turnaround_buffer,
            public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
            public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + requested.turnaround_buffer
          )
      ) then 'Unavailable until 3 hours after return'
      else 'Available'
    end as reason
  from public.vehicles;
$$;

grant execute on function public.get_admin_calendar_fleet_availability(date, text, date, text) to anon, authenticated;

create or replace function public.create_rental_with_lock(
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
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years' then 500
    else 300
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
    '200 miles/day included; excess mileage $0.35/mile'
  ) returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_user_id, v_user_id, 'rental_created',
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'pickup_date', p_pickup_date,
      'return_date', p_return_date,
      'age_tier', case when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years' then 'under_25' else '25_or_older' end,
      'security_deposit', v_security_deposit,
      'source', 'client_portal_admin_calendar_lock'
    )
  );

  return v_rental;
end;
$$;

grant execute on function public.create_rental_with_lock(uuid, date, date, text, text) to authenticated;
