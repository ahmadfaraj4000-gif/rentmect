-- Production RLS policies for Rent Me CT before Stripe/email integration.
-- Run after rentmect_hardening.sql.

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where profiles.id = auth.uid()
      and profiles.role = 'admin'
  );
$$;

grant execute on function public.is_admin() to authenticated;

create or replace function public.rentmect_time_to_time(p_time text)
returns time
language sql
immutable
as $$
  select coalesce(
    case
      when nullif(trim(p_time), '') is null then null
      else trim(p_time)::time
    end,
    '9:00 AM'::time
  );
$$;

create or replace function public.rentmect_rental_timestamp(p_date date, p_time text)
returns timestamp
language sql
immutable
as $$
  select p_date + public.rentmect_time_to_time(p_time);
$$;

create or replace function public.rentmect_periods_overlap(
  p_start_a timestamp,
  p_end_a timestamp,
  p_start_b timestamp,
  p_end_b timestamp
) returns boolean
language sql
immutable
as $$
  select p_start_a < p_end_b and p_end_a > p_start_b;
$$;

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
  where coalesce(lower(rentals.status), '') not in ('completed', 'cancelled')
    and rentals.vehicle_id is not null
    and rentals.pickup_date is not null
    and rentals.return_date is not null;
$$;

grant execute on function public.get_vehicle_booking_blocks() to anon, authenticated;

drop function if exists public.get_fleet_availability(date, date);
drop function if exists public.get_fleet_availability(date, text, date, text);

create function public.get_fleet_availability(
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
	    vehicles.id as vehicle_id,
	    not (
	      coalesce(lower(vehicles.status), 'available') in ('reserved', 'rented', 'maintenance', 'unavailable', 'inactive')
	      or exists (
	        select 1
	        from public.rentals
	        cross join requested
	        where rentals.vehicle_id = vehicles.id
	          and coalesce(lower(rentals.status), '') not in ('completed', 'cancelled')
	          and rentals.pickup_date is not null
	          and rentals.return_date is not null
	          and p_pickup_date is not null
	          and p_return_date is not null
	          and public.rentmect_periods_overlap(
	            requested.pickup_at,
	            requested.return_at,
	            public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
	            public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + requested.turnaround_buffer
	          )
	      )
	    ) as available,
	    case
	      when coalesce(lower(vehicles.status), 'available') in ('reserved', 'rented', 'maintenance', 'unavailable', 'inactive')
	        then 'Unavailable'
	      when exists (
	        select 1
	        from public.rentals
	        cross join requested
	        where rentals.vehicle_id = vehicles.id
	          and coalesce(lower(rentals.status), '') not in ('completed', 'cancelled')
	          and rentals.pickup_date is not null
	          and rentals.return_date is not null
	          and p_pickup_date is not null
	          and p_return_date is not null
	          and public.rentmect_periods_overlap(
	            requested.pickup_at,
	            requested.return_at,
	            public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
	            public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time) + requested.turnaround_buffer
	          )
	      )
	        then 'Unavailable'
	      when p_pickup_date is null or p_return_date is null
        then 'Choose Dates'
      else 'Available'
    end as reason
	  from public.vehicles;
$$;

grant execute on function public.get_fleet_availability(date, text, date, text) to anon, authenticated;

create function public.get_fleet_availability(
  p_pickup_date date,
  p_return_date date
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
  select *
  from public.get_fleet_availability(p_pickup_date, '9:00 AM', p_return_date, '9:00 AM');
$$;

grant execute on function public.get_fleet_availability(date, date) to anon, authenticated;

do $$
begin
  if to_regclass('public.vehicle_reports') is null
     and to_regclass('public.rental_reports') is not null then
    alter table public.rental_reports rename to vehicle_reports;
  end if;
end $$;

alter table public.profiles enable row level security;
alter table public.vehicles enable row level security;
alter table public.rentals enable row level security;
alter table public.pending_bookings enable row level security;
alter table public.rental_documents enable row level security;
alter table public.rental_messages enable row level security;
alter table public.vehicle_reports enable row level security;

drop policy if exists "Profiles are visible to owner or admins" on public.profiles;
create policy "Profiles are visible to owner or admins"
  on public.profiles
  for select
  to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists "Users can create their own profile" on public.profiles;
drop policy if exists "Users can insert own profile" on public.profiles;
drop policy if exists "Admins can create profiles" on public.profiles;
create policy "Admins can create profiles"
  on public.profiles
  for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "Profiles are editable by owner or admins" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Admins can update profiles" on public.profiles;
create policy "Admins can update profiles"
  on public.profiles
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Vehicles are readable for booking" on public.vehicles;
create policy "Vehicles are readable for booking"
  on public.vehicles
  for select
  to anon, authenticated
  using (true);

drop policy if exists "Admins can manage vehicles" on public.vehicles;
create policy "Admins can manage vehicles"
  on public.vehicles
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Customers can read their rentals" on public.rentals;
create policy "Customers can read their rentals"
  on public.rentals
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Users can update own pending rentals" on public.rentals;
drop policy if exists "Customers can update their rental workflow fields" on public.rentals;
drop policy if exists "Admins can update rentals" on public.rentals;
create policy "Admins can update rentals"
  on public.rentals
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Users can create own rentals" on public.rentals;
drop policy if exists "Admins can create rentals" on public.rentals;
create policy "Admins can create rentals"
  on public.rentals
  for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "Admins can delete rentals" on public.rentals;
create policy "Admins can delete rentals"
  on public.rentals
  for delete
  to authenticated
  using (public.is_admin());

drop policy if exists "Pending bookings can be created from website" on public.pending_bookings;
drop policy if exists "Admins can insert pending bookings" on public.pending_bookings;
create policy "Admins can insert pending bookings"
  on public.pending_bookings
  for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "Pending bookings are visible to owner or admins" on public.pending_bookings;
create policy "Pending bookings are visible to owner or admins"
  on public.pending_bookings
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Pending bookings are editable by owner or admins" on public.pending_bookings;
drop policy if exists "Admins can update pending bookings" on public.pending_bookings;
create policy "Admins can update pending bookings"
  on public.pending_bookings
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Admins can delete pending bookings" on public.pending_bookings;
create policy "Admins can delete pending bookings"
  on public.pending_bookings
  for delete
  to authenticated
  using (public.is_admin());

drop policy if exists "Customers can read their rental document rows" on public.rental_documents;
create policy "Customers can read their rental document rows"
  on public.rental_documents
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Customers can insert their rental document rows" on public.rental_documents;
create policy "Customers can insert their rental document rows"
  on public.rental_documents
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and document_type in ('license', 'insurance')
    and status = 'pending_review'
    and exists (
      select 1
      from public.rentals
      where rentals.id = rental_documents.rental_id
        and rentals.user_id = auth.uid()
    )
  );

drop policy if exists "Customers can replace their rental document rows" on public.rental_documents;

drop policy if exists "Admins can manage rental document rows" on public.rental_documents;
create policy "Admins can manage rental document rows"
  on public.rental_documents
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Customers can read their rental messages" on public.rental_messages;
create policy "Customers can read their rental messages"
  on public.rental_messages
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Customers and admins can send rental messages" on public.rental_messages;
drop policy if exists "Customers can send rental messages" on public.rental_messages;
create policy "Customers can send rental messages"
  on public.rental_messages
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and sender_role = 'client'
    and read_by_admin = false
    and read_by_client = true
    and (
      rental_id is null
      or exists (
        select 1
        from public.rentals
        where rentals.id = rental_messages.rental_id
          and rentals.user_id = auth.uid()
      )
    )
  );

drop policy if exists "Customers can update their message read state" on public.rental_messages;

drop policy if exists "Admins can manage rental messages" on public.rental_messages;
create policy "Admins can manage rental messages"
  on public.rental_messages
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Customers can read their vehicle reports" on public.vehicle_reports;
create policy "Customers can read their vehicle reports"
  on public.vehicle_reports
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Customers can create their vehicle reports" on public.vehicle_reports;
create policy "Customers can create their vehicle reports"
  on public.vehicle_reports
  for insert
  to authenticated
  with check (user_id = auth.uid() or public.is_admin());

drop policy if exists "Customers can update their vehicle reports" on public.vehicle_reports;
create policy "Customers can update their vehicle reports"
  on public.vehicle_reports
  for update
  to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

drop policy if exists "Admins can manage vehicle reports" on public.vehicle_reports;
create policy "Admins can manage vehicle reports"
  on public.vehicle_reports
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());
