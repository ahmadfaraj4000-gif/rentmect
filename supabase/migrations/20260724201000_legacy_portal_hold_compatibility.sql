-- Keep the currently deployed client portal working during its rollout.
-- Its legacy flow creates the rental and attaches the already-owned website
-- hold in the next request. Other customers' holds still block the vehicle.

create or replace function public.enforce_rental_schedule_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_test_vehicle_id constant uuid := '00000000-0000-4000-8000-000000000015';
  v_pickup_at timestamp;
  v_return_at timestamp;
begin
  if new.vehicle_id is null
     or new.vehicle_id = v_test_vehicle_id
     or coalesce(lower(new.status), '') = 'cancelled' then
    return new;
  end if;

  if new.pickup_date is null or new.return_date is null then
    raise exception 'Pickup and return dates are required for a scheduled rental.';
  end if;

  v_pickup_at := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time);
  v_return_at := public.rentmect_rental_timestamp(new.return_date, new.return_time);
  if v_return_at <= v_pickup_at then
    raise exception 'Return time must be after pickup time.';
  end if;

  perform pg_advisory_xact_lock(hashtext(new.vehicle_id::text));

  if exists (
    select 1
    from public.rentals r
    where r.id <> new.id
      and r.vehicle_id = new.vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) then
    raise exception 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.';
  end if;

  if exists (
    select 1
    from public.pending_bookings p
    where p.vehicle_id = new.vehicle_id
      and p.id is distinct from new.source_pending_booking_id
      and not (
        p.user_id = new.user_id
        and p.source = 'website'
        and p.pickup_date = new.pickup_date
        and p.return_date = new.return_date
        and coalesce(p.pickup_time, '9:00 AM') = coalesce(new.pickup_time, '9:00 AM')
        and coalesce(p.return_time, '9:00 AM') = coalesce(new.return_time, '9:00 AM')
      )
      and lower(coalesce(p.status, 'pending')) = 'pending'
      and p.expires_at > now()
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(p.pickup_date, p.pickup_time),
        public.rentmect_rental_timestamp(p.return_date, p.return_time) + interval '3 hours'
      )
  ) then
    raise exception 'Vehicle schedule conflict: another customer has an active checkout hold.';
  end if;

  if exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = new.vehicle_id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'Vehicle schedule conflict: the admin calendar blocks this time.';
  end if;

  return new;
end;
$$;
