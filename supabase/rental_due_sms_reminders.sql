-- Twilio SMS reminders for returns and paid rentals needing admin approval.
-- Run after rentmect_hardening.sql and production_rls_policies.sql.

create table if not exists public.rental_return_reminders (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  reminder_type text not null,
  due_at timestamptz not null,
  target_send_at timestamptz not null,
  status text not null default 'pending',
  attempt_count integer not null default 1,
  twilio_message_sid text,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rental_return_reminder_status_check
    check (status in ('pending', 'sent', 'failed'))
);

alter table public.rental_return_reminders
  add column if not exists target_send_at timestamptz;

update public.rental_return_reminders
  set target_send_at = coalesce(target_send_at, created_at)
  where target_send_at is null;

alter table public.rental_return_reminders
  alter column reminder_type drop default,
  alter column target_send_at set not null;

create unique index if not exists rental_return_reminders_one_per_type
  on public.rental_return_reminders (rental_id, reminder_type);

alter table public.rental_return_reminders enable row level security;

drop policy if exists "Admins can read rental return reminders" on public.rental_return_reminders;
create policy "Admins can read rental return reminders"
  on public.rental_return_reminders
  for select
  to authenticated
  using (public.is_admin());

create table if not exists public.rental_admin_sms_alerts (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  alert_type text not null,
  status text not null default 'pending',
  attempt_count integer not null default 1,
  twilio_message_sid text,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rental_admin_sms_alert_status_check
    check (status in ('pending', 'sent', 'failed'))
);

create unique index if not exists rental_admin_sms_alerts_one_per_type
  on public.rental_admin_sms_alerts (rental_id, alert_type);

alter table public.rental_admin_sms_alerts enable row level security;

drop policy if exists "Admins can read rental admin SMS alerts" on public.rental_admin_sms_alerts;
create policy "Admins can read rental admin SMS alerts"
  on public.rental_admin_sms_alerts
  for select
  to authenticated
  using (public.is_admin());

drop function if exists public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer);

create or replace function public.claim_due_rental_return_sms_reminders(
  p_send_after timestamptz default now() - interval '15 minutes',
  p_send_before timestamptz default now() + interval '15 minutes',
  p_limit integer default 100
) returns table (
  reminder_id uuid,
  reminder_type text,
  rental_id uuid,
  user_id uuid,
  customer_phone text,
  customer_name text,
  vehicle_name text,
  return_date date,
  return_time text
)
language sql
security definer
set search_path = public
as $$
  with rentals_due as (
    select
      rentals.id as rental_id,
      rentals.user_id,
      profiles.phone as customer_phone,
      profiles.full_name as customer_name,
      vehicles.name as vehicle_name,
      rentals.return_date,
      rentals.return_time,
      public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
        at time zone 'America/New_York' as due_at
    from public.rentals
    join public.profiles
      on profiles.id = rentals.user_id
    left join public.vehicles
      on vehicles.id = rentals.vehicle_id
    where lower(coalesce(rentals.payment_status, '')) = 'paid'
      and coalesce(lower(rentals.status), '') not in ('completed', 'cancelled', 'return_initiated')
      and coalesce(profiles.phone_verified, false)
      and coalesce(profiles.sms_transactional_opt_in, false)
      and nullif(trim(profiles.phone), '') is not null
      and rentals.return_date is not null
  ),
  reminder_windows as (
    select
      rentals_due.*,
      reminder_window.reminder_type,
      reminder_window.target_send_at
    from rentals_due
    cross join lateral (
      values
        (
          'return_due_previous_morning_sms'::text,
          (
            public.rentmect_rental_timestamp(rentals_due.return_date - 1, '9:00 AM')
              at time zone 'America/New_York'
          )
        ),
        ('return_due_3h_sms'::text, rentals_due.due_at - interval '3 hours')
    ) as reminder_window(reminder_type, target_send_at)
    where reminder_window.target_send_at >= p_send_after
      and reminder_window.target_send_at < p_send_before
    order by reminder_window.target_send_at
    limit greatest(least(coalesce(p_limit, 100), 300), 1)
  ),
  claimed as (
    insert into public.rental_return_reminders (
      rental_id,
      user_id,
      reminder_type,
      due_at,
      target_send_at
    )
    select
      reminder_windows.rental_id,
      reminder_windows.user_id,
      reminder_windows.reminder_type,
      reminder_windows.due_at,
      reminder_windows.target_send_at
    from reminder_windows
    on conflict (rental_id, reminder_type)
      do update
        set status = 'pending',
            attempt_count = public.rental_return_reminders.attempt_count + 1,
            last_error = null,
            updated_at = now()
      where (
          public.rental_return_reminders.status = 'failed'
          and public.rental_return_reminders.updated_at < now() - interval '5 minutes'
        )
        or (
          public.rental_return_reminders.status = 'pending'
          and public.rental_return_reminders.updated_at < now() - interval '15 minutes'
        )
    returning
      public.rental_return_reminders.id,
      public.rental_return_reminders.rental_id,
      public.rental_return_reminders.reminder_type
  )
  select
    claimed.id as reminder_id,
    claimed.reminder_type,
    reminder_windows.rental_id,
    reminder_windows.user_id,
    reminder_windows.customer_phone,
    reminder_windows.customer_name,
    reminder_windows.vehicle_name,
    reminder_windows.return_date,
    reminder_windows.return_time
  from claimed
  join reminder_windows
    on reminder_windows.rental_id = claimed.rental_id
   and reminder_windows.reminder_type = claimed.reminder_type;
$$;

revoke all on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) from public;
grant execute on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) to service_role;

-- Automated customer return SMS remains disabled until messaging approval is
-- received. Keep this override in the bootstrap source as well as the release
-- migration so rebuilding the database cannot silently re-enable it.
create or replace function public.claim_due_rental_return_sms_reminders(
  p_send_after timestamptz default now() - interval '15 minutes',
  p_send_before timestamptz default now() + interval '15 minutes',
  p_limit integer default 100
) returns table (
  reminder_id uuid,
  reminder_type text,
  rental_id uuid,
  user_id uuid,
  customer_phone text,
  customer_name text,
  vehicle_name text,
  return_date date,
  return_time text
)
language sql
security definer
set search_path = public
as $$
  select
    null::uuid,
    null::text,
    null::uuid,
    null::uuid,
    null::text,
    null::text,
    null::text,
    null::date,
    null::text
  where false;
$$;

comment on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer)
  is 'Automated customer return SMS is disabled pending messaging approval. This function intentionally returns no rows.';

revoke all on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) from public;
grant execute on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) to service_role;

drop function if exists public.claim_paid_rental_admin_sms_alerts(integer);

create or replace function public.claim_paid_rental_admin_sms_alerts(
  p_limit integer default 50,
  p_rental_id uuid default null
) returns table (
  alert_id uuid,
  rental_id uuid,
  customer_name text,
  customer_phone text,
  vehicle_name text,
  pickup_date date,
  pickup_time text,
  rental_status text
)
language sql
security definer
set search_path = public
as $$
  with candidates as (
    select
      rentals.id as rental_id,
      profiles.full_name as customer_name,
      profiles.phone as customer_phone,
      vehicles.name as vehicle_name,
      rentals.pickup_date,
      rentals.pickup_time,
      rentals.status as rental_status
    from public.rentals
    left join public.profiles
      on profiles.id = rentals.user_id
    left join public.vehicles
      on vehicles.id = rentals.vehicle_id
    where lower(coalesce(rentals.payment_status, '')) = 'paid'
      and coalesce(lower(rentals.status), '') in ('pending', 'documents_needed', 'document_review', 'ready_for_pickup')
      and (p_rental_id is null or rentals.id = p_rental_id)
    order by rentals.paid_at nulls last, rentals.created_at
    limit greatest(least(coalesce(p_limit, 50), 200), 1)
  ),
  claimed as (
    insert into public.rental_admin_sms_alerts (
      rental_id,
      alert_type
    )
    select
      candidates.rental_id,
      'paid_rental_needs_approval_sms'
    from candidates
    on conflict (rental_id, alert_type)
      do update
        set status = 'pending',
            attempt_count = public.rental_admin_sms_alerts.attempt_count + 1,
            last_error = null,
            updated_at = now()
      where (
          public.rental_admin_sms_alerts.status = 'failed'
          and public.rental_admin_sms_alerts.updated_at < now() - interval '5 minutes'
        )
        or (
          public.rental_admin_sms_alerts.status = 'pending'
          and public.rental_admin_sms_alerts.updated_at < now() - interval '15 minutes'
        )
    returning
      public.rental_admin_sms_alerts.id,
      public.rental_admin_sms_alerts.rental_id
  )
  select
    claimed.id as alert_id,
    candidates.rental_id,
    candidates.customer_name,
    candidates.customer_phone,
    candidates.vehicle_name,
    candidates.pickup_date,
    candidates.pickup_time,
    candidates.rental_status
  from claimed
  join candidates
    on candidates.rental_id = claimed.rental_id;
$$;

revoke all on function public.claim_paid_rental_admin_sms_alerts(integer, uuid) from public;
grant execute on function public.claim_paid_rental_admin_sms_alerts(integer, uuid) to service_role;
