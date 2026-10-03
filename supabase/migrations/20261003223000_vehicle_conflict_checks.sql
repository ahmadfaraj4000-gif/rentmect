begin;

-- One conflict reader for admin availability and the existing write guards.
-- Assignment history preserves the actual start of a replacement vehicle.
create or replace function public.rentmect_vehicle_conflicts(
  p_vehicle_id uuid, p_from timestamptz, p_until timestamptz,
  p_rental_id uuid default null, p_pending_id uuid default null
) returns table(kind text, source_id uuid, starts_at timestamptz, ends_at timestamptz, reason text)
language sql stable security definer set search_path=public as $$
  with assignments as (
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
  select 'vehicle',v.id,null::timestamptz,null::timestamptz,
    coalesce(nullif(v.maintenance_lock_reason,''),'Vehicle unavailable or under maintenance')
  from vehicles v where v.id=p_vehicle_id and (v.is_active=false or coalesce(v.maintenance_lock_active,false)
    or lower(coalesce(v.status,'')) in ('maintenance','unavailable','inactive','retired'))
  union all
  select 'physical_return',r.id,null::timestamptz,null::timestamptz,'Awaiting physical return and inspection'
  from rentals r where r.vehicle_id=p_vehicle_id and r.id is distinct from p_rental_id
    and rentmect_requires_physical_return_lock(r.status,r.return_date,r.return_time)
  union all
  select 'reservation',a.rental_id,a.starts_at,a.ends_at,'Reserved rental (three-hour turnaround protected)'
  from assignments a where a.ends_at>a.starts_at and p_from<a.ends_at+interval '3 hours' and p_until+interval '3 hours'>a.starts_at
  union all
  select 'calendar_block',b.id,rentmect_rental_timestamp(b.start_date,b.start_time) at time zone 'America/New_York',
    rentmect_rental_timestamp(b.end_date,b.end_time) at time zone 'America/New_York',coalesce(nullif(b.label,''),'Calendar block')
  from vehicle_availability_blocks b where b.vehicle_id=p_vehicle_id and coalesce(b.active,true)
    and lower(coalesce(b.block_type,'unavailable'))<>'available'
    and p_from<(rentmect_rental_timestamp(b.end_date,b.end_time) at time zone 'America/New_York')
    and p_until+interval '3 hours'>(rentmect_rental_timestamp(b.start_date,b.start_time) at time zone 'America/New_York')
  union all
  select 'checkout_hold',b.id,rentmect_rental_timestamp(b.pickup_date,b.pickup_time) at time zone 'America/New_York',
    rentmect_rental_timestamp(b.return_date,b.return_time) at time zone 'America/New_York','Another customer has an active checkout hold'
  from pending_bookings b where b.vehicle_id=p_vehicle_id and b.id is distinct from p_pending_id
    and b.status='pending' and b.expires_at>now()
    and p_from<(rentmect_rental_timestamp(b.return_date,b.return_time) at time zone 'America/New_York')+interval '3 hours'
    and p_until+interval '3 hours'>(rentmect_rental_timestamp(b.pickup_date,b.pickup_time) at time zone 'America/New_York');
$$;
revoke all on function public.rentmect_vehicle_conflicts(uuid,timestamptz,timestamptz,uuid,uuid) from public,anon,authenticated;

create or replace function public.rentmect_assert_swap_available(p_rental_id uuid,p_vehicle_id uuid,p_from timestamptz,p_until timestamptz)
returns void language plpgsql security definer set search_path=public as $$
declare conflict record;
begin
  if p_from is null or p_until is null or p_until<=p_from then raise exception 'Choose a valid availability window.'; end if;
  perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));
  select * into conflict from public.rentmect_vehicle_conflicts(p_vehicle_id,p_from,p_until,p_rental_id) limit 1;
  if found then raise exception 'Replacement vehicle conflicts: %',conflict.reason; end if;
end; $$;

-- Keep existing trigger behavior, adding the shared check after its current
-- checks. This preserves the existing cancellation, hold-conversion and swap paths.
do $migration$
declare definition text; marker text:='  return new;'; insertion text;
begin
  select pg_get_functiondef('public.enforce_rental_schedule_integrity()'::regprocedure) into definition;
  insertion:=$guard$
  if lower(coalesce(new.status,'')) not in ('completed','cancelled') then
    if exists(select 1 from public.rentmect_vehicle_conflicts(new.vehicle_id,
      requested_start at time zone 'America/New_York',requested_end at time zone 'America/New_York',new.id,new.source_pending_booking_id)) then
      raise exception 'Vehicle unavailable: conflicting reservation, three-hour turnaround, maintenance, calendar block, or checkout hold.';
    end if;
    if new.status in ('active','rented') and (tg_op='INSERT' or old.status not in ('active','rented','overdue','return_initiated') or old.vehicle_id is distinct from new.vehicle_id)
      and exists(select 1 from rentals r where r.vehicle_id=new.vehicle_id and r.id<>new.id
        and r.status in ('active','rented','overdue','return_initiated') and r.inspection_completed_at is null) then
      raise exception 'This vehicle is still with another customer. Complete its physical return before releasing it again.';
    end if;
  end if;
  return new;
$guard$;
  if position(E'\n  return new;\nend;' in definition)=0 then raise exception 'Review rental guard before applying migration.'; end if;
  execute replace(definition,E'\n  return new;\nend;',E'\n'||insertion||E'\nend;');
  select pg_get_functiondef('public.enforce_pending_booking_schedule_integrity()'::regprocedure) into definition;
  insertion:=$guard$
  if exists(select 1 from public.rentmect_vehicle_conflicts(new.vehicle_id,
    requested_start at time zone 'America/New_York',requested_end at time zone 'America/New_York',null,new.id)) then
    raise exception 'Vehicle unavailable: conflicting reservation, three-hour turnaround, maintenance, calendar block, or checkout hold.';
  end if;
  return new;
$guard$;
  if position(E'\n  return new;\nend;' in definition)=0 then raise exception 'Review checkout guard before applying migration.'; end if;
  execute replace(definition,E'\n  return new;\nend;',E'\n'||insertion||E'\nend;');
end; $migration$;

create or replace function public.admin_rental_vehicle_availability(p_rental_id uuid,p_from timestamptz,p_until timestamptz,p_vehicle_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
  if auth.uid() is null or not coalesce(public.is_admin(),false) or not coalesce(public.rentmect_has_permission('rental.edit'),false) then
    raise exception 'Rental editing permission is required.'; end if;
  if not exists(select 1 from rentals where id=p_rental_id) then raise exception 'Rental not found.'; end if;
  if p_from is null or p_until is null or p_until<=p_from then raise exception 'Choose a valid availability window.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('vehicle_id',v.id,'available',jsonb_array_length(c.conflicts)=0,'conflicts',c.conflicts,
    'next_reservation',next_booking.details) order by v.name),'[]') into result
  from vehicles v
  cross join lateral (select coalesce(jsonb_agg(to_jsonb(conflict)),'[]') conflicts from rentmect_vehicle_conflicts(v.id,p_from,p_until,p_rental_id) conflict) c
  left join lateral (select jsonb_build_object('starts_at',rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
    'ends_at',rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') details
    from rentals r where r.vehicle_id=v.id and r.id<>p_rental_id and r.status not in ('completed','cancelled')
      and (rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')>=p_from
    order by rentmect_rental_timestamp(r.pickup_date,r.pickup_time) limit 1) next_booking on true
  where (p_vehicle_id is null or v.id=p_vehicle_id) and v.id<>'00000000-0000-4000-8000-000000000015';
  return result;
end; $$;
revoke all on function public.admin_rental_vehicle_availability(uuid,timestamptz,timestamptz,uuid) from public,anon;
grant execute on function public.admin_rental_vehicle_availability(uuid,timestamptz,timestamptz,uuid) to authenticated;
-- Both the customer fleet and admin booking picker already call this reader.
-- Keep its public output limited to generic reasons, without reservation details.
create or replace function public.get_admin_calendar_fleet_availability(p_pickup_date date,p_pickup_time text,p_return_date date,p_return_time text)
returns table(vehicle_id uuid,available boolean,reason text)
language sql stable security definer set search_path=public as $$
  with requested as (select rentmect_rental_timestamp(p_pickup_date,p_pickup_time) at time zone 'America/New_York' starts,
    rentmect_rental_timestamp(p_return_date,p_return_time) at time zone 'America/New_York' ends)
  select v.id,coalesce(req.ends>req.starts,false) and c.kind is null,
    case when not coalesce(req.ends>req.starts,false) then 'Choose a valid date and time window'
      when c.kind='physical_return' then 'Vehicle awaiting physical return and inspection'
      when c.kind='vehicle' then 'Vehicle unavailable'
      when c.kind='checkout_hold' then 'Another customer is checking out this vehicle'
      when c.kind='calendar_block' then 'Blocked on the Rent Me CT calendar'
      when c.kind is not null then 'Unavailable: reserved dates or three-hour turnaround'
      else 'Available' end
  from vehicles v cross join requested req
  left join lateral (select conflict.kind from rentmect_vehicle_conflicts(v.id,req.starts,req.ends) conflict limit 1) c on true;
$$;
notify pgrst,'reload schema';
commit;
