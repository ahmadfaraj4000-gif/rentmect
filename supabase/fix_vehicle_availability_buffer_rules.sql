-- Availability correction:
-- reserved/rented are workflow labels, not all-day/global availability blockers.
-- Actual booking availability is controlled by rental pickup/return windows plus
-- a 3-hour turnaround buffer after return.

create or replace function public.get_fleet_availability(
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
      coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
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
      when coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
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
        then 'Unavailable until 3 hours after return'
      when p_pickup_date is null or p_return_date is null
        then 'Choose Dates'
      else 'Available'
    end as reason
  from public.vehicles;
$$;

grant execute on function public.get_fleet_availability(date, text, date, text) to anon, authenticated;

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
  v_days integer;
  v_rental public.rentals%rowtype;
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_turnaround_buffer interval := interval '3 hours';
begin
  if v_user_id is null then
    raise exception 'You must be signed in to create a rental.';
  end if;

  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;

  if exists (
    select 1
    from public.profiles
    where profiles.id = v_user_id
      and (
        coalesce(profiles.blocked_customer, false)
        or coalesce(profiles.customer_status, 'good') = 'blocked'
      )
  ) then
    raise exception 'This account is blocked from booking. Please contact Rent Me CT.';
  end if;

  v_days := (p_return_date - p_pickup_date);
  if v_days < 1 then
    raise exception 'Return date must be after pickup date.';
  end if;

  v_pickup_at := public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time);
  v_return_at := public.rentmect_rental_timestamp(p_return_date, p_return_time);
  if v_return_at <= v_pickup_at then
    raise exception 'Return time must be after pickup time.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));

  select *
    into v_vehicle
    from public.vehicles
    where id = p_vehicle_id
    for update;

  if not found then
    raise exception 'Vehicle not found.';
  end if;

  if coalesce(lower(v_vehicle.status), 'available') in ('maintenance', 'unavailable', 'inactive') then
    raise exception 'This vehicle is not available for booking.';
  end if;

  if exists (
    select 1
      from public.rentals r
      where r.vehicle_id = p_vehicle_id
        and coalesce(lower(r.status), '') not in ('completed', 'cancelled')
        and r.pickup_date is not null
        and r.return_date is not null
        and public.rentmect_periods_overlap(
          v_pickup_at,
          v_return_at,
          public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
          public.rentmect_rental_timestamp(r.return_date, r.return_time) + v_turnaround_buffer
        )
  ) then
    raise exception 'This vehicle is already booked for that pickup and return time.';
  end if;

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
  )
  values (
    v_user_id,
    p_vehicle_id,
    p_pickup_date,
    p_return_date,
    coalesce(p_pickup_time, '9:00 AM'),
    coalesce(p_return_time, '9:00 AM'),
    'documents_needed',
    coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    coalesce(v_vehicle.security_deposit, 0),
    'pending',
    'pending',
    '200 miles/day included; excess mileage $0.35/mile'
  )
  returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_user_id,
    v_user_id,
    'rental_created',
    jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'pickup_date', p_pickup_date,
      'return_date', p_return_date,
      'source', 'create_rental_with_lock'
    )
  );

  return v_rental;
end;
$$;

grant execute on function public.create_rental_with_lock(uuid, date, date, text, text) to authenticated;

create or replace function public.record_admin_local_rental_payment(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required to record a local payment.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be marked paid.';
  end if;

  if coalesce(lower(v_rental.payment_status), 'pending') = 'paid' then
    raise exception 'This rental is already paid.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_rental.user_id and coalesce(p.phone_verified, false)
  ) or not public.rentmect_identity_is_verified(v_rental.user_id) then
    raise exception 'Phone and identity verification must be complete before recording payment.';
  end if;

  if not coalesce(v_rental.agreement_signed, false) then
    raise exception 'The customer must sign the rental agreement before payment can be recorded.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and lower(coalesce(d.document_type, '')) in ('license', 'drivers_license', 'driver_license')
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'An approved driver license is required before recording payment.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and d.rental_id = v_rental.id
      and lower(coalesce(d.document_type, '')) = 'insurance'
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'Approved insurance for this rental is required before recording payment.';
  end if;

  update public.rentals
    set payment_status = 'paid',
        deposit_status = 'held',
        paid_at = coalesce(paid_at, now()),
        deposit_held_amount = greatest(
          coalesce(deposit_held_amount, 0),
          coalesce(security_deposit, 0)
        )
    where id = p_rental_id
    returning * into v_rental;

  update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and coalesce(lower(status), 'available') not in ('maintenance', 'unavailable', 'inactive');

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_local_payment_recorded',
    jsonb_build_object('source', 'record_admin_local_rental_payment')
  );

  return v_rental;
end;
$$;

revoke all on function public.record_admin_local_rental_payment(uuid) from public;
grant execute on function public.record_admin_local_rental_payment(uuid) to authenticated;

-- Return inspection + damage evidence used by the admin portal before closing
-- a returned rental. Admin can skip checklist, but the skip is still recorded.
create table if not exists public.rental_return_inspections (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  admin_id uuid default auth.uid() references public.profiles(id) on delete set null,
  mileage_checked boolean not null default false,
  fuel_checked boolean not null default false,
  damage_checked boolean not null default false,
  damage_found boolean not null default false,
  deposit_decision text not null default 'release'
    check (deposit_decision in ('release', 'hold')),
  notes text,
  skipped boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.rental_return_inspections enable row level security;

drop policy if exists "Admins can manage return inspections" on public.rental_return_inspections;
create policy "Admins can manage return inspections"
  on public.rental_return_inspections
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create table if not exists public.vehicle_reports (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid references public.rentals(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  status text not null default 'open',
  description text,
  created_at timestamptz not null default now()
);

alter table public.vehicle_reports
  add column if not exists vehicle_id uuid references public.vehicles(id) on delete set null,
  add column if not exists report_type text default 'customer_report',
  add column if not exists issue_type text default 'damage',
  add column if not exists photo_paths jsonb not null default '[]'::jsonb,
  add column if not exists deposit_held_amount numeric default 0,
  add column if not exists estimated_cost numeric default 0,
  add column if not exists final_charge_amount numeric default 0,
  add column if not exists admin_notes text,
  add column if not exists resolved_at timestamptz;

alter table public.profiles
  add column if not exists customer_status text not null default 'good'
    check (customer_status in ('good', 'review_required', 'blocked')),
  add column if not exists block_reason text,
  add column if not exists blocked_at timestamptz;

alter table public.vehicle_reports enable row level security;

drop policy if exists "Admins can manage vehicle reports" on public.vehicle_reports;
create policy "Admins can manage vehicle reports"
  on public.vehicle_reports
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Customers can read their vehicle reports" on public.vehicle_reports;
create policy "Customers can read their vehicle reports"
  on public.vehicle_reports
  for select
  to authenticated
  using (user_id = auth.uid());

create or replace function public.admin_set_customer_status(
  p_user_id uuid,
  p_customer_status text,
  p_block_reason text default null
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  if p_customer_status not in ('good', 'review_required', 'blocked') then
    raise exception 'Invalid customer status.';
  end if;

  update public.profiles
    set customer_status = p_customer_status,
        blocked_customer = p_customer_status = 'blocked',
        block_reason = case when p_customer_status = 'good' then null else nullif(trim(p_block_reason), '') end,
        blocked_at = case when p_customer_status = 'blocked' then now() else null end
    where id = p_user_id
    returning * into v_profile;

  if not found then
    raise exception 'Customer profile not found.';
  end if;

  return v_profile;
end;
$$;

revoke all on function public.admin_set_customer_status(uuid, text, text) from public;
grant execute on function public.admin_set_customer_status(uuid, text, text) to authenticated;

-- Admin return damage photos are stored in the same private bucket as rental
-- documents so signed URLs still work with the existing admin document flow.
do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Admins can upload rental damage evidence'
  ) then
    create policy "Admins can upload rental damage evidence"
      on storage.objects
      for insert
      to authenticated
      with check (
        bucket_id = 'rental-documents'
        and public.is_admin()
      );
  end if;
end $$;

-- Global auto-ready logic. Any avenue that completes payment, agreement, or
-- document approval can promote the rental to ready_for_pickup.
create or replace function public.sync_rental_ready_for_pickup_global(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
begin
  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    return null;
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('documents_needed', 'document_review', 'approved') then
    return v_rental;
  end if;

  if not exists (
    select 1
    from public.profiles
    where profiles.id = v_rental.user_id
      and coalesce(profiles.phone_verified, false)
  ) then
    return v_rental;
  end if;

  if not coalesce(v_rental.agreement_signed, false)
     or lower(coalesce(v_rental.payment_status, '')) <> 'paid' then
    return v_rental;
  end if;

  if not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where rental_documents.user_id = v_rental.user_id
        and rental_documents.document_type = 'license'
      order by rental_documents.created_at desc nulls last
      limit 1
    ) latest_license
    where lower(coalesce(latest_license.status, '')) = 'approved'
  ) or not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where rental_documents.rental_id = v_rental.id
        and rental_documents.user_id = v_rental.user_id
        and rental_documents.document_type = 'insurance'
      order by rental_documents.created_at desc nulls last
      limit 1
    ) latest_insurance
    where lower(coalesce(latest_insurance.status, '')) = 'approved'
  ) then
    return v_rental;
  end if;

  update public.rentals
    set status = 'ready_for_pickup'
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and coalesce(lower(status), 'available') not in ('maintenance', 'unavailable', 'inactive');

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    auth.uid(),
    'rental_auto_ready_for_pickup',
    jsonb_build_object('source', 'sync_rental_ready_for_pickup_global')
  );

  return v_rental;
end;
$$;

revoke all on function public.sync_rental_ready_for_pickup_global(uuid) from public;
grant execute on function public.sync_rental_ready_for_pickup_global(uuid) to authenticated;

create or replace function public.sync_rental_ready_after_rental_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.sync_rental_ready_for_pickup_global(new.id);
  return new;
end;
$$;

drop trigger if exists rentals_auto_ready_for_pickup on public.rentals;
create trigger rentals_auto_ready_for_pickup
after insert or update of payment_status, agreement_signed, status
on public.rentals
for each row
execute function public.sync_rental_ready_after_rental_update();

create or replace function public.sync_rental_ready_after_document_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental_id uuid;
begin
  if new.rental_id is not null then
    perform public.sync_rental_ready_for_pickup_global(new.rental_id);
  end if;

  if new.document_type = 'license' then
    for v_rental_id in
      select rentals.id
      from public.rentals
      where rentals.user_id = new.user_id
        and lower(coalesce(rentals.status, '')) in ('documents_needed', 'document_review', 'approved')
    loop
      perform public.sync_rental_ready_for_pickup_global(v_rental_id);
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists rental_documents_auto_ready_for_pickup on public.rental_documents;
create trigger rental_documents_auto_ready_for_pickup
after insert or update of status
on public.rental_documents
for each row
execute function public.sync_rental_ready_after_document_update();
