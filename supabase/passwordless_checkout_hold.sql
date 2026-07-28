-- Persistent 25-minute holds for website -> passwordless client checkout.
-- Run after customer_surface_security_hardening.sql, stripe_payments.sql, and
-- client_portal_calendar_source_of_truth.sql.

alter table public.pending_bookings
  add column if not exists expires_at timestamptz;

update public.pending_bookings
set expires_at = coalesce(created_at, now()) + interval '25 minutes'
where expires_at is null;

alter table public.pending_bookings
  alter column expires_at set default (now() + interval '25 minutes'),
  alter column expires_at set not null;

alter table public.rentals
  add column if not exists checkout_expires_at timestamptz;

create index if not exists pending_bookings_expires_at_idx
  on public.pending_bookings (expires_at)
  where status = 'pending';

create index if not exists rentals_checkout_expires_at_idx
  on public.rentals (checkout_expires_at)
  where payment_status <> 'paid' and stripe_checkout_session_id is null;

create or replace function public.create_website_pending_booking(
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text default '9:00 AM',
  p_return_time text default '9:00 AM',
  p_vehicle_id uuid default null,
  p_selected_vehicle_name text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
begin
  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;

  if p_return_date <= p_pickup_date then
    raise exception 'Return date must be after pickup date.';
  end if;

  insert into public.pending_bookings (
    pickup_date, return_date, pickup_time, return_time, vehicle_id,
    selected_vehicle_name, status, source, expires_at
  ) values (
    p_pickup_date,
    p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    p_vehicle_id,
    nullif(trim(p_selected_vehicle_name), ''),
    'pending',
    'website',
    now() + interval '25 minutes'
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$$;

revoke all on function public.create_website_pending_booking(date, date, text, text, uuid, text) from public;
grant execute on function public.create_website_pending_booking(date, date, text, text, uuid, text) to anon, authenticated;

drop function if exists public.get_website_pending_booking(uuid);
create function public.get_website_pending_booking(
  p_booking_id uuid
) returns table (
  id uuid,
  pickup_date date,
  return_date date,
  pickup_time text,
  return_time text,
  vehicle_id uuid,
  selected_vehicle_name text,
  expires_at timestamptz,
  status text
)
language sql
security definer
set search_path = public
as $$
  select
    pending_bookings.id,
    pending_bookings.pickup_date,
    pending_bookings.return_date,
    pending_bookings.pickup_time,
    pending_bookings.return_time,
    pending_bookings.vehicle_id,
    pending_bookings.selected_vehicle_name,
    pending_bookings.expires_at,
    pending_bookings.status
  from public.pending_bookings
  where pending_bookings.id = p_booking_id
    and pending_bookings.source = 'website'
    and coalesce(lower(pending_bookings.status), 'pending') in ('pending', 'expired');
$$;

revoke all on function public.get_website_pending_booking(uuid) from public;
grant execute on function public.get_website_pending_booking(uuid) to anon, authenticated;

create or replace function public.claim_customer_pending_booking(
  p_booking_id uuid,
  p_vehicle_id uuid default null,
  p_customer_phone text default null
) returns public.pending_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_booking public.pending_bookings%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to claim a booking.';
  end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Pending booking not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;

  if v_booking.expires_at <= now() then
    update public.pending_bookings
    set status = 'expired', updated_at = now()
    where id = p_booking_id
    returning * into v_booking;
    return v_booking;
  end if;

  if coalesce(lower(v_booking.status), 'pending') <> 'pending' then return v_booking; end if;

  update public.pending_bookings
  set user_id = v_user_id,
      customer_email = coalesce(v_email, customer_email),
      customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
      vehicle_id = coalesce(p_vehicle_id, vehicle_id),
      updated_at = now()
  where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.claim_customer_pending_booking(uuid, uuid, text) from public;
grant execute on function public.claim_customer_pending_booking(uuid, uuid, text) to authenticated;

create or replace function public.attach_customer_checkout_hold(
  p_booking_id uuid,
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_booking public.pending_bookings%rowtype;
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then raise exception 'You must be signed in.'; end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Pending booking not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id and user_id = v_user_id
  for update;

  if not found then raise exception 'Rental not found.'; end if;

  if v_booking.expires_at <= now() or lower(coalesce(v_booking.status, 'pending')) = 'expired' then
    update public.pending_bookings
    set status = 'expired', user_id = coalesce(user_id, v_user_id), updated_at = now()
    where id = p_booking_id;

    update public.rentals
    set status = 'cancelled', checkout_expires_at = v_booking.expires_at, updated_at = now()
    where id = p_rental_id
      and coalesce(payment_status, 'pending') <> 'paid'
      and stripe_checkout_session_id is null
    returning * into v_rental;

    return v_rental;
  end if;

  update public.rentals
  set checkout_expires_at = v_booking.expires_at, updated_at = now()
  where id = p_rental_id
  returning * into v_rental;

  return v_rental;
end;
$$;

revoke all on function public.attach_customer_checkout_hold(uuid, uuid) from public;
grant execute on function public.attach_customer_checkout_hold(uuid, uuid) to authenticated;

create or replace function public.convert_customer_pending_booking(
  p_booking_id uuid,
  p_vehicle_id uuid default null,
  p_customer_phone text default null
) returns public.pending_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_booking public.pending_bookings%rowtype;
begin
  if v_user_id is null then raise exception 'You must be signed in to convert a booking.'; end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Pending booking not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;
  if v_booking.expires_at <= now() or lower(coalesce(v_booking.status, 'pending')) = 'expired' then
    raise exception 'This 25-minute checkout hold has expired. Please start a new booking.';
  end if;

  update public.pending_bookings
  set user_id = v_user_id,
      customer_email = coalesce(v_email, customer_email),
      customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
      vehicle_id = coalesce(p_vehicle_id, vehicle_id),
      status = 'converted',
      updated_at = now()
  where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.convert_customer_pending_booking(uuid, uuid, text) from public;
grant execute on function public.convert_customer_pending_booking(uuid, uuid, text) to authenticated;

create or replace function public.expire_customer_checkout_hold(
  p_booking_id uuid,
  p_rental_id uuid default null
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'You must be signed in.'; end if;

  update public.pending_bookings
  set status = 'expired', updated_at = now()
  where id = p_booking_id
    and source = 'website'
    and (user_id is null or user_id = v_user_id)
    and expires_at <= now();

  if p_rental_id is not null then
    update public.rentals
    set status = 'cancelled', updated_at = now()
    where id = p_rental_id
      and user_id = v_user_id
      and checkout_expires_at <= now()
      and coalesce(payment_status, 'pending') <> 'paid'
      and stripe_checkout_session_id is null
      and lower(coalesce(status, 'pending')) in ('pending', 'documents_needed', 'document_review');

    if found then
      insert into public.rental_audit_events (
        rental_id, user_id, actor_id, event_type, event_payload
      ) values (
        p_rental_id,
        v_user_id,
        v_user_id,
        'customer_checkout_hold_expired',
        jsonb_build_object('expired_at', now(), 'source', 'client_portal')
      );
    end if;
  end if;

  return true;
end;
$$;

revoke all on function public.expire_customer_checkout_hold(uuid, uuid) from public;
grant execute on function public.expire_customer_checkout_hold(uuid, uuid) to authenticated;

create or replace function public.expire_stale_customer_checkout_holds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cancelled integer := 0;
begin
  update public.pending_bookings
  set status = 'expired', updated_at = now()
  where status = 'pending' and expires_at <= now();

  with cancelled as (
    update public.rentals
    set status = 'cancelled', updated_at = now()
    where checkout_expires_at <= now()
      and coalesce(payment_status, 'pending') <> 'paid'
      and stripe_checkout_session_id is null
      and lower(coalesce(status, 'pending')) in ('pending', 'documents_needed', 'document_review')
    returning id, user_id
  ), audited as (
    insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
    select id, user_id, null, 'customer_checkout_hold_expired', jsonb_build_object('expired_at', now())
    from cancelled
    returning rental_id
  )
  select count(*) into v_cancelled from audited;

  return v_cancelled;
end;
$$;

revoke all on function public.expire_stale_customer_checkout_holds() from public;
grant execute on function public.expire_stale_customer_checkout_holds() to service_role;

create extension if not exists pg_cron;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-expire-checkout-holds';

select cron.schedule(
  'rentmect-expire-checkout-holds',
  '* * * * *',
  $$select public.expire_stale_customer_checkout_holds();$$
);
