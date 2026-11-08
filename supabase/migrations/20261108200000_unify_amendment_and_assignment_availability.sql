-- Keep edits, swaps, extensions and checkout on one availability decision.
-- Audit assignment history is retained; only actual possession reserves old vehicles.
do $migration$
declare definition text;
 old_block text := $old$  with assignments as (
    select a.rental_id,a.vehicle_id,a.assigned_from starts_at,
      case when a.vehicle_id=r.vehicle_id and a.id=(select last_a.id from rental_vehicle_assignments last_a where last_a.rental_id=r.id order by last_a.assigned_from desc,last_a.created_at desc limit 1)
        then coalesce(r.inspection_completed_at,rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')
        else a.assigned_until end ends_at
    from rental_vehicle_assignments a join rentals r on r.id=a.rental_id
    where a.vehicle_id=p_vehicle_id and r.id is distinct from p_rental_id and r.status<>'cancelled'
    union all
    select r.id,r.vehicle_id,rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
      coalesce(r.inspection_completed_at,rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')
    from rentals r where r.vehicle_id=p_vehicle_id and r.id is distinct from p_rental_id and r.status not in ('completed','cancelled')
      and not exists(select 1 from rental_vehicle_assignments a where a.rental_id=r.id and a.vehicle_id=r.vehicle_id)
  )
$old$;
 new_block text := $new$  with assignments as (
    -- Before pickup, retained audit assignments are not physical possession.
    -- Reserve only the current vehicle and the current booked window.
    select a.rental_id,a.vehicle_id,
      greatest(a.assigned_from,rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York') starts_at,
      case when a.vehicle_id=r.vehicle_id and a.id=(select last_a.id from rental_vehicle_assignments last_a where last_a.rental_id=r.id order by last_a.assigned_from desc,last_a.created_at desc limit 1)
        then coalesce(r.inspection_completed_at,rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')
        else least(a.assigned_until,coalesce(r.inspection_completed_at,a.assigned_until)) end ends_at
    from rental_vehicle_assignments a join rentals r on r.id=a.rental_id
    where a.vehicle_id=p_vehicle_id and r.id is distinct from p_rental_id and r.status<>'cancelled'
      and (r.status in ('active','rented','overdue','return_initiated','completed') or r.starting_mileage is not null or r.inspection_completed_at is not null)
    union all
    select r.id,r.vehicle_id,rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
      coalesce(r.inspection_completed_at,rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')
    from rentals r where r.vehicle_id=p_vehicle_id and r.id is distinct from p_rental_id and r.status<>'cancelled'
      and (r.status<>'completed' or r.inspection_completed_at is not null)
      and ((r.status not in ('active','rented','overdue','return_initiated','completed') and r.starting_mileage is null and r.inspection_completed_at is null)
        or not exists(select 1 from rental_vehicle_assignments a where a.rental_id=r.id and a.vehicle_id=r.vehicle_id))
  )
$new$;
begin
 select pg_get_functiondef('public.rentmect_vehicle_conflicts(uuid,timestamptz,timestamptz,uuid,uuid)'::regprocedure) into definition;
 if position(new_block in definition)>0 then return; end if;
 if position(old_block in definition)=0 then raise exception 'Review changed canonical availability definition before migrating.'; end if;
 definition:=replace(definition,old_block,new_block);
 execute definition;
end;
$migration$;

do $migration$
declare definition text;
 old_block text := $old$  if v_core_changed and exists (
    select 1
    from public.rentals rentals
    where rentals.id <> v_rental.id
      and rentals.vehicle_id = p_vehicle_id
      and lower(coalesce(rentals.status, '')) not in ('completed', 'cancelled')
      and rentals.pickup_date is not null
      and rentals.return_date is not null
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
        public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
          + interval '3 hours'
      )
  ) then
    raise exception 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.';
  end if;

  if v_core_changed and exists (
    select 1
    from public.vehicle_availability_blocks blocks
    where blocks.vehicle_id = p_vehicle_id
      and coalesce(blocks.active, true)
      and lower(coalesce(blocks.block_type, 'unavailable')) <> 'available'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(blocks.start_date, blocks.start_time),
        public.rentmect_rental_timestamp(blocks.end_date, blocks.end_time)
      )
  ) then
    raise exception 'Vehicle schedule conflict: the admin calendar blocks this time.';
  end if;

$old$;
 new_block text := $new$  if v_core_changed then
    select * into v_schedule_conflict
    from public.rentmect_vehicle_conflicts(
      p_vehicle_id, v_pickup_at at time zone 'America/New_York',
      v_return_at at time zone 'America/New_York', v_rental.id, v_rental.source_pending_booking_id
    ) limit 1;
    if found then
      case v_schedule_conflict.kind
        when 'reservation' then
          raise exception 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.';
        when 'calendar_block' then
          raise exception 'Vehicle schedule conflict: the admin calendar blocks this time.';
        when 'physical_return' then
          raise exception 'Vehicle schedule conflict: awaiting physical return and inspection.';
        when 'checkout_hold' then
          raise exception 'Vehicle schedule conflict: another customer has an active checkout hold.';
        else
          raise exception 'Vehicle schedule conflict: %',v_schedule_conflict.reason;
      end case;
    end if;
  end if;

$new$;
begin
 select pg_get_functiondef('public.admin_preview_rental_amendment_without_manual_discount(uuid,uuid,date,text,date,text,numeric,numeric)'::regprocedure) into definition;
 if position(new_block in definition)>0 then return; end if;
 if position(old_block in definition)=0 then raise exception 'Review changed preview availability definition before migrating.'; end if;
 definition:=replace(definition,old_block,new_block);
 if position(E'  v_settlement_status text;
begin' in definition)=0 then raise exception 'Review changed amendment declarations before migrating.'; end if;
 definition:=replace(definition,E'  v_settlement_status text;
begin',E'  v_settlement_status text;
  v_schedule_conflict record;
begin');
 execute definition;
end;
$migration$;

