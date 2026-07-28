-- Rent Me CT operational hardening.
-- Run this in the Supabase SQL editor before deploying the portal changes.

create extension if not exists pgcrypto;

alter table public.rentals
  add column if not exists payment_status text default 'pending',
  add column if not exists deposit_status text default 'pending',
  add column if not exists paid_at timestamptz,
  add column if not exists agreement_version text,
  add column if not exists agreement_snapshot text,
  add column if not exists agreement_hash text,
  add column if not exists agreement_signed_at timestamptz,
  add column if not exists agreement_signature_name text,
  add column if not exists agreement_ip text,
  add column if not exists agreement_user_agent text,
  add column if not exists mileage_policy text default '200 miles/day included; excess mileage $0.35/mile',
  add column if not exists cancellation_terms text default 'Contact Rent Me CT before pickup for cancellation or schedule changes.',
  add column if not exists admin_notes text,
  add column if not exists blocked_customer boolean default false,
  add column if not exists chargeback_count integer default 0,
  add column if not exists late_return_count integer default 0,
  add column if not exists deposit_held_amount numeric default 0,
  add column if not exists deposit_released_amount numeric default 0;

alter table public.profiles
  add column if not exists admin_notes text,
  add column if not exists blocked_customer boolean default false;

alter table public.pending_bookings
  add column if not exists vehicle_id uuid references public.vehicles(id);

alter table public.rental_signatures
  add column if not exists agreement_version text,
  add column if not exists agreement_snapshot text,
  add column if not exists agreement_hash text,
  add column if not exists ip_address text,
  add column if not exists user_agent text,
  add column if not exists vehicle_id uuid,
  add column if not exists rental_total numeric,
  add column if not exists tax_amount numeric,
  add column if not exists security_deposit numeric,
  add column if not exists mileage_policy text,
  add column if not exists signed_at timestamptz default now();

create table if not exists public.rental_audit_events (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid references public.rentals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  event_payload jsonb default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.rental_audit_events enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'rental_audit_events'
      and policyname = 'Admins can read rental audit events'
  ) then
    create policy "Admins can read rental audit events"
      on public.rental_audit_events
      for select
      to authenticated
      using (
        exists (
          select 1
          from public.profiles
          where profiles.id = auth.uid()
            and profiles.role = 'admin'
        )
      );
  end if;
end $$;

create or replace function public.rental_dates_overlap(
  start_a date,
  end_a date,
  start_b date,
  end_b date
) returns boolean
language sql
immutable
as $$
  select start_a <= end_b and end_a >= start_b;
$$;

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

  if coalesce(lower(v_vehicle.status), 'available') in ('reserved', 'rented', 'maintenance', 'unavailable', 'inactive') then
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

create or replace function public.sign_rental_agreement(
  p_rental_id uuid,
  p_signature_name text,
  p_agreement_version text,
  p_agreement_snapshot text,
  p_agreement_hash text,
  p_user_agent text default null
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
  v_ip text;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to sign an agreement.';
  end if;

  if nullif(trim(p_signature_name), '') is null then
    raise exception 'Signature name is required.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  v_ip := coalesce(
    v_headers ->> 'x-forwarded-for',
    v_headers ->> 'cf-connecting-ip',
    v_headers ->> 'x-real-ip'
  );

  insert into public.rental_signatures (
    user_id,
    rental_id,
    signature_name,
    signature_data,
    agreement_version,
    agreement_snapshot,
    agreement_hash,
    ip_address,
    user_agent,
    vehicle_id,
    rental_total,
    tax_amount,
    security_deposit,
    mileage_policy,
    signed_at
  )
  values (
    v_user_id,
    p_rental_id,
    trim(p_signature_name),
    'Typed signature: ' || trim(p_signature_name),
    p_agreement_version,
    p_agreement_snapshot,
    p_agreement_hash,
    v_ip,
    p_user_agent,
    v_rental.vehicle_id,
    v_rental.rental_total,
    v_rental.tax_amount,
    v_rental.security_deposit,
    coalesce(v_rental.mileage_policy, '200 miles/day included; excess mileage $0.35/mile'),
    now()
  );

  update public.rentals
    set agreement_signed = true,
        agreement_version = p_agreement_version,
        agreement_snapshot = p_agreement_snapshot,
        agreement_hash = p_agreement_hash,
        agreement_signed_at = now(),
        agreement_signature_name = trim(p_signature_name),
        agreement_ip = v_ip,
        agreement_user_agent = p_user_agent
    where id = p_rental_id
    returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    p_rental_id,
    v_user_id,
    v_user_id,
    'agreement_signed',
    jsonb_build_object(
      'agreement_version', p_agreement_version,
      'agreement_hash', p_agreement_hash,
      'ip_address', v_ip
    )
  );

  return v_rental;
end;
$$;

grant execute on function public.sign_rental_agreement(uuid, text, text, text, text, text) to authenticated;
