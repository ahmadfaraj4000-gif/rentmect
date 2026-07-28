-- Run after fix_vehicle_availability_buffer_rules.sql.
-- Replace the vehicle id/date values if you are testing a different car/window.

-- Example vehicle from the current fleet: Kia Soul #656
-- a3e97226-347e-4154-905c-3c8c22613600

select
  '11 AM should be blocked if the vehicle returns at 9 AM that same day' as test,
  vehicle_id,
  available,
  reason
from public.get_fleet_availability(
  '2026-05-27'::date,
  '11:00 AM'::text,
  '2026-05-28'::date,
  '9:00 AM'::text
)
where vehicle_id = 'a3e97226-347e-4154-905c-3c8c22613600';

select
  '12 PM should be available after a 9 AM return plus 3 hour buffer' as test,
  vehicle_id,
  available,
  reason
from public.get_fleet_availability(
  '2026-05-27'::date,
  '12:00 PM'::text,
  '2026-05-28'::date,
  '9:00 AM'::text
)
where vehicle_id = 'a3e97226-347e-4154-905c-3c8c22613600';

-- Full audit view for a vehicle. Use this when a result surprises you.
select
  vehicles.id as vehicle_id,
  vehicles.name,
  vehicles.status as vehicle_status,
  rentals.id as rental_id,
  rentals.status as rental_status,
  rentals.pickup_date,
  rentals.pickup_time,
  rentals.return_date,
  rentals.return_time,
  public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + interval '3 hours' as blocked_until
from public.vehicles
left join public.rentals
  on rentals.vehicle_id = vehicles.id
 and coalesce(lower(rentals.status), '') not in ('completed', 'cancelled')
where vehicles.id = 'a3e97226-347e-4154-905c-3c8c22613600'
order by rentals.pickup_date, rentals.pickup_time;
