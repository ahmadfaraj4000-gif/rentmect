-- Bulletproof rental lifecycle and inventory locking.
-- This migration makes temporary holds real scheduling blocks, gives every
-- unpaid reservation a deadline, and makes return inspection/vehicle release
-- one atomic admin action.

alter table public.rentals
  add column if not exists booking_source text not null default 'customer_portal',
  add column if not exists source_pending_booking_id uuid references public.pending_bookings(id) on delete set null,
  add column if not exists payment_due_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists cancellation_reason text,
  add column if not exists trip_change_intent text,
  add column if not exists return_initiated_at timestamptz,
  add column if not exists inspection_completed_at timestamptz;

alter table public.rental_extension_requests
  add column if not exists payment_due_at timestamptz;

create unique index if not exists rentals_source_pending_booking_unique_idx
  on public.rentals (source_pending_booking_id)
  where source_pending_booking_id is not null;

create index if not exists rentals_unpaid_deadline_idx
  on public.rentals (payment_due_at)
  where coalesce(lower(payment_status), 'pending') <> 'paid'
    and coalesce(lower(status), '') not in ('cancelled', 'completed');

create index if not exists pending_bookings_vehicle_active_hold_idx
  on public.pending_bookings (vehicle_id, pickup_date, return_date, expires_at)
  where status = 'pending' and vehicle_id is not null;

create or replace function public.initialize_rental_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pickup_at timestamptz;
begin
  if tg_op = 'INSERT' then
    if public.is_admin() and new.source_pending_booking_id is null then
      new.booking_source := 'admin_manual';
    elsif coalesce(new.booking_source, '') = '' then
      new.booking_source := 'customer_portal';
    end if;

    if coalesce(lower(new.payment_status), 'pending') <> 'paid' then
      if new.booking_source = 'admin_manual' then
        v_pickup_at := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time)
          at time zone 'America/New_York';
        new.payment_due_at := coalesce(
          new.payment_due_at,
          case
            when v_pickup_at <= now() + interval '3 hours' then now() + interval '1 hour'
            else least(now() + interval '24 hours', v_pickup_at - interval '2 hours')
          end
        );
        new.checkout_expires_at := null;
      else
        new.checkout_expires_at := coalesce(new.checkout_expires_at, now() + interval '25 minutes');
        new.payment_due_at := coalesce(new.payment_due_at, new.checkout_expires_at);
      end if;
    end if;
  end if;

  if coalesce(lower(new.payment_status), 'pending') = 'paid' then
    new.checkout_expires_at := null;
    new.payment_due_at := null;
  end if;

  if tg_op = 'UPDATE'
     and lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;

  return new;
end;
$$;

drop trigger if exists rentals_initialize_lifecycle on public.rentals;
create trigger rentals_initialize_lifecycle
before insert or update of payment_status, status
on public.rentals
for each row execute function public.initialize_rental_lifecycle();

create or replace function public.prevent_cancelled_rental_payment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(coalesce(new.payment_status, '')) = 'paid'
     and lower(coalesce(old.payment_status, '')) <> 'paid'
     and lower(coalesce(old.status, '')) = 'cancelled' then
    raise exception 'Cancelled reservations cannot be marked paid. Refund the late payment.';
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_prevent_cancelled_payment on public.rentals;
create trigger rentals_prevent_cancelled_payment
before update of payment_status on public.rentals
for each row execute function public.prevent_cancelled_rental_payment();

create or replace function public.initialize_extension_payment_deadline()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'approved_pending_payment'
     and coalesce(old.status, '') <> 'approved_pending_payment' then
    new.payment_due_at := coalesce(new.payment_due_at, now() + interval '2 hours');
  elsif new.status in ('activated', 'rejected', 'cancelled') then
    new.payment_due_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists extension_requests_payment_deadline on public.rental_extension_requests;
create trigger extension_requests_payment_deadline
before update of status
on public.rental_extension_requests
for each row execute function public.initialize_extension_payment_deadline();

create or replace function public.enforce_pending_booking_schedule_integrity()
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
     or lower(coalesce(new.status, 'pending')) <> 'pending'
     or new.expires_at <= now() then
    return new;
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
    where r.vehicle_id = new.vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) then
    raise exception 'This vehicle is already reserved for that time.';
  end if;

  if exists (
    select 1
    from public.pending_bookings p
    where p.id <> new.id
      and p.vehicle_id = new.vehicle_id
      and lower(coalesce(p.status, 'pending')) = 'pending'
      and p.expires_at > now()
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(p.pickup_date, p.pickup_time),
        public.rentmect_rental_timestamp(p.return_date, p.return_time) + interval '3 hours'
      )
  ) then
    raise exception 'Another customer is currently checking out this vehicle.';
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
    raise exception 'This vehicle is blocked on the calendar for that time.';
  end if;

  return new;
end;
$$;

drop trigger if exists pending_bookings_schedule_integrity on public.pending_bookings;
create trigger pending_bookings_schedule_integrity
before insert or update of vehicle_id, pickup_date, return_date, pickup_time, return_time, status, expires_at
on public.pending_bookings
for each row execute function public.enforce_pending_booking_schedule_integrity();

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

drop trigger if exists enforce_rental_schedule_integrity on public.rentals;
create trigger enforce_rental_schedule_integrity
before insert or update of vehicle_id, pickup_date, return_date, pickup_time, return_time, status
on public.rentals
for each row execute function public.enforce_rental_schedule_integrity();

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
  if public.rentmect_rental_timestamp(p_return_date, p_return_time)
     <= public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time) then
    raise exception 'Return time must be after pickup time.';
  end if;

  insert into public.pending_bookings (
    pickup_date, return_date, pickup_time, return_time, vehicle_id,
    selected_vehicle_name, status, source, expires_at
  ) values (
    p_pickup_date, p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    p_vehicle_id, nullif(trim(p_selected_vehicle_name), ''),
    'pending', 'website', now() + interval '25 minutes'
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$$;

revoke all on function public.create_website_pending_booking(date, date, text, text, uuid, text) from public;
grant execute on function public.create_website_pending_booking(date, date, text, text, uuid, text) to anon, authenticated;

create or replace function public.convert_website_hold_to_rental(
  p_booking_id uuid,
  p_customer_phone text default null
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_booking public.pending_bookings%rowtype;
  v_profile public.profiles%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_rental public.rentals%rowtype;
  v_days integer;
  v_security_deposit numeric;
begin
  if v_user_id is null then raise exception 'You must be signed in.'; end if;

  select * into v_booking
  from public.pending_bookings
  where id = p_booking_id and source = 'website'
  for update;

  if not found then raise exception 'Checkout hold not found.'; end if;
  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'This checkout hold belongs to another customer.';
  end if;
  if lower(coalesce(v_booking.status, 'pending')) <> 'pending'
     or v_booking.expires_at <= now() then
    update public.pending_bookings
      set status = 'expired', updated_at = now()
      where id = v_booking.id and status = 'pending';
    raise exception 'This 25-minute checkout hold expired. Please start a new booking.';
  end if;
  if v_booking.vehicle_id is null then raise exception 'Choose a vehicle before continuing.'; end if;

  perform pg_advisory_xact_lock(hashtext(v_booking.vehicle_id::text));

  select * into v_profile from public.profiles where id = v_user_id for update;
  if not found or v_profile.date_of_birth is null or v_profile.date_of_birth > current_date then
    raise exception 'Add a valid date of birth before booking.';
  end if;
  if coalesce(v_profile.blocked_customer, false)
     or coalesce(v_profile.customer_status, 'good') = 'blocked' then
    raise exception 'This account is blocked from booking. Please contact Rent Me CT.';
  end if;

  select * into v_vehicle from public.vehicles where id = v_booking.vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if coalesce(lower(v_vehicle.status), 'available') in ('maintenance', 'unavailable', 'inactive') then
    raise exception 'This vehicle is not available for booking.';
  end if;

  v_days := v_booking.return_date - v_booking.pickup_date;
  if v_days < 1 then raise exception 'Return date must be after pickup date.'; end if;
  v_security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth) < interval '25 years' then 500
    else 300
  end;

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status,
    deposit_status, mileage_policy, checkout_expires_at, payment_due_at,
    source_pending_booking_id, booking_source
  ) values (
    v_user_id, v_booking.vehicle_id, v_booking.pickup_date, v_booking.return_date,
    v_booking.pickup_time, v_booking.return_time,
    'documents_needed', coalesce(v_vehicle.daily_rate, 0) * v_days,
    coalesce(v_vehicle.daily_rate, 0) * v_days * 0.0635,
    v_security_deposit, 'pending', 'pending',
    '200 miles/day included; excess mileage $0.35/mile',
    v_booking.expires_at, v_booking.expires_at, v_booking.id, 'website_hold'
  )
  returning * into v_rental;

  update public.pending_bookings
    set user_id = v_user_id,
        customer_email = coalesce(nullif(auth.jwt() ->> 'email', ''), customer_email),
        customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
        status = 'converted',
        updated_at = now()
    where id = v_booking.id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_user_id, v_user_id, 'website_hold_converted',
    jsonb_build_object('pending_booking_id', v_booking.id, 'expires_at', v_booking.expires_at)
  );

  return v_rental;
end;
$$;

revoke all on function public.convert_website_hold_to_rental(uuid, text) from public;
grant execute on function public.convert_website_hold_to_rental(uuid, text) to authenticated;

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
  select r.id, r.vehicle_id, r.pickup_date, r.return_date, r.pickup_time,
         r.return_time, r.status, r.payment_status, r.deposit_status, r.paid_at
  from public.rentals r
  where coalesce(lower(r.status), '') <> 'cancelled'
    and r.vehicle_id is not null and r.pickup_date is not null and r.return_date is not null

  union all

  select p.id, p.vehicle_id, p.pickup_date, p.return_date, p.pickup_time,
         p.return_time, 'checkout_hold'::text, null::text, null::text, null::timestamptz
  from public.pending_bookings p
  where lower(coalesce(p.status, 'pending')) = 'pending'
    and p.expires_at > now() and p.vehicle_id is not null

  union all

  select b.id, b.vehicle_id, b.start_date, b.end_date, b.start_time,
         b.end_time, 'calendar_block'::text, null::text, null::text, null::timestamptz
  from public.vehicle_availability_blocks b
  where coalesce(b.active, true)
    and coalesce(lower(b.block_type), 'unavailable') <> 'available';
$$;

grant execute on function public.get_vehicle_booking_blocks() to anon, authenticated;

create or replace function public.get_admin_calendar_fleet_availability(
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
      public.rentmect_rental_timestamp(p_return_date, p_return_time) as return_at
  ),
  conflicts as (
    select distinct on (blocks.vehicle_id) blocks.vehicle_id,
      case
        when blocks.status = 'checkout_hold' then 'Another customer is checking out this vehicle'
        when blocks.status = 'calendar_block' then 'Blocked on the Rent Me CT calendar'
        else 'Unavailable until 3 hours after return'
      end as reason
    from public.get_vehicle_booking_blocks() blocks
    cross join requested
    where public.rentmect_periods_overlap(
      requested.pickup_at,
      requested.return_at + interval '3 hours',
      public.rentmect_rental_timestamp(blocks.pickup_date, blocks.pickup_time),
      public.rentmect_rental_timestamp(blocks.return_date, blocks.return_time) + interval '3 hours'
    )
    order by blocks.vehicle_id,
      case blocks.status
        when 'checkout_hold' then 1
        when 'calendar_block' then 2
        else 3
      end
  )
  select
    vehicles.id,
    not (
      coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
      or conflicts.vehicle_id is not null
    ) as available,
    case
      when coalesce(lower(vehicles.status), 'available') in ('maintenance', 'unavailable', 'inactive')
        then 'Vehicle unavailable'
      when conflicts.vehicle_id is not null then conflicts.reason
      else 'Available'
    end
  from public.vehicles
  left join conflicts on conflicts.vehicle_id = vehicles.id;
$$;

grant execute on function public.get_admin_calendar_fleet_availability(date, text, date, text)
  to anon, authenticated;

create or replace function public.expire_stale_customer_checkout_holds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cancelled integer := 0;
  v_extension record;
begin
  update public.pending_bookings
    set status = 'expired', updated_at = now()
    where status = 'pending' and expires_at <= now();

  for v_extension in
    update public.rental_extension_requests
      set status = 'cancelled',
          payment_due_at = null,
          updated_at = now()
      where status = 'approved_pending_payment'
        and coalesce(payment_status, 'pending') <> 'paid'
        and payment_due_at <= now()
      returning id, rental_id, user_id
  loop
    perform public.release_extension_calendar_hold(v_extension.id);
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    ) values (
      v_extension.rental_id, v_extension.user_id, null,
      'extension_payment_deadline_expired',
      jsonb_build_object('extension_request_id', v_extension.id, 'expired_at', now())
    );
  end loop;

  with cancelled as (
    update public.rentals
      set status = 'cancelled',
          cancelled_at = now(),
          cancellation_reason = case
            when booking_source = 'admin_manual' then 'Payment deadline expired'
            else '25-minute checkout deadline expired'
          end,
          updated_at = now()
      where coalesce(lower(payment_status), 'pending') <> 'paid'
        and lower(coalesce(status, 'pending')) in
          ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup')
        and coalesce(payment_due_at, checkout_expires_at) <= now()
      returning id, user_id, booking_source, stripe_checkout_session_id
  ), audited as (
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    )
    select id, user_id, null, 'unpaid_reservation_expired',
           jsonb_build_object(
             'expired_at', now(),
             'booking_source', booking_source,
             'stripe_checkout_session_id', stripe_checkout_session_id
           )
    from cancelled
    returning rental_id
  )
  select count(*) into v_cancelled from audited;

  return v_cancelled;
end;
$$;

revoke all on function public.expire_stale_customer_checkout_holds() from public;
grant execute on function public.expire_stale_customer_checkout_holds() to service_role;

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
      set status = 'cancelled',
          cancelled_at = now(),
          cancellation_reason = '25-minute checkout deadline expired',
          updated_at = now()
      where id = p_rental_id
        and user_id = v_user_id
        and coalesce(payment_due_at, checkout_expires_at) <= now()
        and coalesce(lower(payment_status), 'pending') <> 'paid'
        and lower(coalesce(status, 'pending')) in
          ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup');

    if found then
      insert into public.rental_audit_events (
        rental_id, user_id, actor_id, event_type, event_payload
      ) values (
        p_rental_id, v_user_id, v_user_id, 'customer_checkout_hold_expired',
        jsonb_build_object('expired_at', now(), 'source', 'client_portal')
      );
    end if;
  end if;

  return true;
end;
$$;

revoke all on function public.expire_customer_checkout_hold(uuid, uuid) from public;
grant execute on function public.expire_customer_checkout_hold(uuid, uuid) to authenticated;

create or replace function public.admin_extend_rental_payment_deadline(
  p_rental_id uuid,
  p_payment_due_at timestamptz,
  p_reason text
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
    raise exception 'Admin access is required.';
  end if;
  if p_payment_due_at is null or p_payment_due_at <= now() then
    raise exception 'Choose a future payment deadline.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Enter a reason for changing the deadline.';
  end if;

  update public.rentals
    set payment_due_at = p_payment_due_at,
        checkout_expires_at = case
          when booking_source = 'admin_manual' then null else p_payment_due_at
        end,
        updated_at = now()
    where id = p_rental_id
      and coalesce(lower(payment_status), 'pending') <> 'paid'
      and lower(coalesce(status, '')) not in ('cancelled', 'completed', 'active', 'overdue', 'return_initiated')
    returning * into v_rental;

  if not found then raise exception 'Only an open unpaid reservation can be extended.'; end if;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_payment_deadline_extended',
    jsonb_build_object('payment_due_at', p_payment_due_at, 'reason', trim(p_reason))
  );
  return v_rental;
end;
$$;

revoke all on function public.admin_extend_rental_payment_deadline(uuid, timestamptz, text) from public;
grant execute on function public.admin_extend_rental_payment_deadline(uuid, timestamptz, text) to authenticated;

drop function if exists public.admin_cancel_rental(uuid);
create or replace function public.admin_cancel_rental(
  p_rental_id uuid,
  p_reason text default 'Cancelled by admin'
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Enter a cancellation reason.'; end if;

  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) in ('completed', 'cancelled', 'active', 'overdue', 'return_initiated') then
    raise exception 'This rental cannot be cancelled from the guarded action.';
  end if;
  if lower(coalesce(v_rental.payment_status, 'pending')) = 'paid' then
    raise exception 'Paid reservations require the refund/cancellation workflow.';
  end if;

  update public.rentals
    set status = 'cancelled',
        cancelled_at = now(),
        cancelled_by = v_admin_id,
        cancellation_reason = trim(p_reason),
        updated_at = now()
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = 'available'
    where id = v_rental.vehicle_id and lower(coalesce(status, '')) = 'reserved';

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_cancelled',
    jsonb_build_object('reason', trim(p_reason), 'payment_status', v_rental.payment_status)
  );
  return v_rental;
end;
$$;

revoke all on function public.admin_cancel_rental(uuid, text) from public;
grant execute on function public.admin_cancel_rental(uuid, text) to authenticated;

create or replace function public.set_customer_trip_change_intent(
  p_rental_id uuid,
  p_intent text
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then raise exception 'You must be signed in.'; end if;
  if p_intent not in ('return', 'extend', 'exchange') then
    raise exception 'Choose return, extend, or exchange.';
  end if;

  update public.rentals
    set trip_change_intent = p_intent, updated_at = now()
    where id = p_rental_id
      and user_id = v_user_id
      and lower(coalesce(status, '')) in ('active', 'overdue', 'return_initiated')
    returning * into v_rental;
  if not found then raise exception 'Only an active rental can be changed.'; end if;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_user_id, v_user_id, 'customer_trip_change_intent',
    jsonb_build_object('intent', p_intent)
  );
  return v_rental;
end;
$$;

revoke all on function public.set_customer_trip_change_intent(uuid, text) from public;
grant execute on function public.set_customer_trip_change_intent(uuid, text) to authenticated;

create or replace function public.initiate_customer_rental_return(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then raise exception 'You must be signed in to update a rental.'; end if;
  select * into v_rental
    from public.rentals
    where id = p_rental_id and user_id = v_user_id
    for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'return_initiated' then return v_rental; end if;
  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Only an active rental can start a return.';
  end if;
  if exists (
    select 1 from public.rental_extension_requests
    where rental_id = p_rental_id and user_id = v_user_id
      and status in ('pending', 'approved_pending_payment')
  ) then
    raise exception 'Resolve or cancel the open extension/exchange request before returning.';
  end if;

  update public.rentals
    set status = 'return_initiated',
        trip_change_intent = 'return',
        return_initiated_at = now(),
        updated_at = now()
    where id = p_rental_id
    returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    p_rental_id, v_user_id, v_user_id, 'rental_return_initiated',
    jsonb_build_object('source', 'customer_portal', 'return_initiated_at', now())
  );
  return v_rental;
end;
$$;

revoke all on function public.initiate_customer_rental_return(uuid) from public;
grant execute on function public.initiate_customer_rental_return(uuid) to authenticated;

create or replace function public.admin_inspect_and_complete_rental_return(
  p_rental_id uuid,
  p_ending_mileage integer,
  p_mileage_checked boolean,
  p_fuel_checked boolean,
  p_damage_checked boolean,
  p_damage_found boolean,
  p_deposit_decision text,
  p_notes text default null,
  p_vehicle_disposition text default 'available'
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_ending_mileage is null or p_ending_mileage < 0 then raise exception 'Ending mileage is required.'; end if;
  if not coalesce(p_mileage_checked, false)
     or not coalesce(p_fuel_checked, false)
     or not coalesce(p_damage_checked, false) then
    raise exception 'Mileage, fuel, and condition must all be inspected before the vehicle is released.';
  end if;
  if p_deposit_decision not in ('release', 'hold') then raise exception 'Choose release or hold for the deposit.'; end if;
  if p_vehicle_disposition not in ('available', 'maintenance', 'unavailable') then
    raise exception 'Choose a valid vehicle disposition.';
  end if;
  if p_damage_found and (p_deposit_decision <> 'hold' or p_vehicle_disposition = 'available') then
    raise exception 'Damage requires a held deposit and a maintenance/unavailable vehicle disposition.';
  end if;
  if (p_damage_found or p_deposit_decision = 'hold')
     and length(trim(coalesce(p_notes, ''))) < 5 then
    raise exception 'Add inspection notes explaining the damage or deposit hold.';
  end if;

  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) <> 'return_initiated' then
    raise exception 'The customer/admin must initiate the return before inspection can close it.';
  end if;
  if v_rental.starting_mileage is not null and p_ending_mileage < v_rental.starting_mileage then
    raise exception 'Ending mileage cannot be below starting mileage.';
  end if;

  insert into public.rental_return_inspections (
    rental_id, user_id, admin_id, mileage_checked, ending_mileage,
    fuel_checked, damage_checked, damage_found, deposit_decision, notes, skipped
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id, true, p_ending_mileage,
    true, true, p_damage_found, p_deposit_decision, nullif(trim(p_notes), ''), false
  );

  update public.rentals
    set status = 'completed',
        ending_mileage = p_ending_mileage,
        inspection_completed_at = now(),
        deposit_status = case
          when p_deposit_decision = 'hold' then 'held'
          else deposit_status
        end,
        deposit_release_due_at = case
          when p_deposit_decision = 'hold' then null
          else deposit_release_due_at
        end,
        deposit_release_reason = case
          when p_deposit_decision = 'hold' then 'Held after return inspection: ' || trim(p_notes)
          else deposit_release_reason
        end,
        updated_at = now()
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = p_vehicle_disposition,
        current_mileage = p_ending_mileage
    where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_return_inspection_completed',
    jsonb_build_object(
      'ending_mileage', p_ending_mileage,
      'damage_found', p_damage_found,
      'deposit_decision', p_deposit_decision,
      'vehicle_disposition', p_vehicle_disposition,
      'notes', nullif(trim(p_notes), '')
    )
  );
  return v_rental;
end;
$$;

revoke all on function public.admin_inspect_and_complete_rental_return(
  uuid, integer, boolean, boolean, boolean, boolean, text, text, text
) from public;
grant execute on function public.admin_inspect_and_complete_rental_return(
  uuid, integer, boolean, boolean, boolean, boolean, text, text, text
) to authenticated;

-- Preserve currently open manual bookings and give staff/customer a fresh,
-- visible 24-hour deadline when lifecycle deadlines are introduced.
update public.rentals
set booking_source = 'admin_manual',
    payment_due_at = coalesce(payment_due_at, now() + interval '24 hours'),
    checkout_expires_at = null
where coalesce(lower(payment_status), 'pending') <> 'paid'
  and lower(coalesce(status, '')) in
    ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup')
  and coalesce(admin_notes, '') ilike '%created manually in the admin portal%';

update public.rentals
set payment_due_at = checkout_expires_at
where coalesce(lower(payment_status), 'pending') <> 'paid'
  and payment_due_at is null
  and checkout_expires_at is not null;

update public.rental_extension_requests
set payment_due_at = now() + interval '2 hours'
where status = 'approved_pending_payment'
  and coalesce(payment_status, 'pending') <> 'paid'
  and payment_due_at is null;

-- Immediately release already-expired unpaid reservations when this migration lands.
select public.expire_stale_customer_checkout_holds();
