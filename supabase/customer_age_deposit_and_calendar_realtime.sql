-- Run after the existing Rent Me CT hardening migrations.
-- Makes rentals the live calendar source of truth and enforces the under-25 deposit server-side.

alter table public.profiles
  add column if not exists date_of_birth date;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rentals'
  ) then
    alter publication supabase_realtime add table public.rentals;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'vehicle_availability_blocks'
  ) then
    alter publication supabase_realtime add table public.vehicle_availability_blocks;
  end if;
end;
$$;

create or replace function public.save_customer_profile_contact_details(
  p_full_name text,
  p_phone text,
  p_address text,
  p_date_of_birth date
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_profile public.profiles%rowtype;
  v_phone text := nullif(trim(p_phone), '');
  v_phone_changed boolean := false;
begin
  if v_user_id is null then raise exception 'You must be signed in to save a profile.'; end if;
  if p_date_of_birth is null or p_date_of_birth > current_date then
    raise exception 'A valid date of birth is required.';
  end if;

  select * into v_profile from public.profiles where id = v_user_id for update;
  if found then
    v_phone_changed := coalesce(v_profile.phone, '') is distinct from coalesce(v_phone, '');
    update public.profiles
      set email = coalesce(v_email, email),
          full_name = nullif(trim(p_full_name), ''),
          phone = v_phone,
          address = nullif(trim(p_address), ''),
          date_of_birth = p_date_of_birth,
          phone_verified = case when v_phone_changed then false else phone_verified end,
          phone_verified_at = case when v_phone_changed then null else phone_verified_at end,
          phone_verification_method = case when v_phone_changed then null else phone_verification_method end,
          phone_verification_updated_at = case when v_phone_changed then null else phone_verification_updated_at end
      where id = v_user_id returning * into v_profile;
  else
    insert into public.profiles (id, email, full_name, phone, address, date_of_birth, phone_verified)
    values (v_user_id, v_email, nullif(trim(p_full_name), ''), v_phone, nullif(trim(p_address), ''), p_date_of_birth, false)
    returning * into v_profile;
  end if;
  return v_profile;
end;
$$;

drop function if exists public.save_customer_profile_contact_details(text, text, text);
revoke all on function public.save_customer_profile_contact_details(text, text, text, date) from public;
grant execute on function public.save_customer_profile_contact_details(text, text, text, date) to authenticated;

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
    select 1 from public.rentals r
    where r.vehicle_id = p_vehicle_id
      and coalesce(lower(r.status), '') not in ('completed', 'cancelled')
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at,
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + v_turnaround_buffer
      )
  ) then
    raise exception 'This vehicle is already booked for that pickup and return time.';
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
    coalesce(p_pickup_time, '9:00 AM'), coalesce(p_return_time, '9:00 AM'),
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
      'source', 'create_rental_with_lock'
    )
  );
  return v_rental;
end;
$$;

grant execute on function public.create_rental_with_lock(uuid, date, date, text, text) to authenticated;
