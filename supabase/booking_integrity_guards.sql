-- Final database backstop for real fleet scheduling.
-- Run after admin_pricing_settings.sql and client_portal_calendar_source_of_truth.sql.
--
-- The booking RPCs already lock and validate availability. This trigger protects
-- direct inserts, imports, extension activation, and any future write path too.
-- The fixed Booking Preview vehicle remains exempt so QA can create repeatable,
-- non-production test rentals without consuming real inventory.

create index if not exists rentals_vehicle_schedule_idx
  on public.rentals (vehicle_id, pickup_date, return_date)
  where vehicle_id is not null and coalesce(lower(status), '') <> 'cancelled';

create index if not exists vehicle_availability_blocks_schedule_idx
  on public.vehicle_availability_blocks (vehicle_id, start_date, end_date)
  where active and coalesce(lower(block_type), 'unavailable') <> 'available';

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
      and r.pickup_date is not null
      and r.return_date is not null
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

drop trigger if exists enforce_rental_schedule_integrity on public.rentals;
create trigger enforce_rental_schedule_integrity
before insert or update of vehicle_id, pickup_date, return_date, pickup_time, return_time, status
on public.rentals
for each row
execute function public.enforce_rental_schedule_integrity();

