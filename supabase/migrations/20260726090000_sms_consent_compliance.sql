-- Records affirmative transactional-SMS consent and prevents customer SMS
-- reminders from being claimed unless the current phone has an active opt-in.

alter table public.profiles
  add column if not exists sms_transactional_opt_in boolean not null default false,
  add column if not exists sms_transactional_opted_in_at timestamptz,
  add column if not exists sms_transactional_opted_out_at timestamptz,
  add column if not exists sms_transactional_consent_source text,
  add column if not exists sms_transactional_consent_version text,
  add column if not exists sms_transactional_consent_text text;

create table if not exists public.sms_consent_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  phone text,
  status text not null check (status in ('opted_in', 'opted_out')),
  source text not null,
  consent_version text not null,
  consent_text text not null,
  occurred_at timestamptz not null default now()
);

create index if not exists sms_consent_events_user_time_idx
  on public.sms_consent_events (user_id, occurred_at desc);

alter table public.sms_consent_events enable row level security;

drop policy if exists "Customers can read their SMS consent history" on public.sms_consent_events;
create policy "Customers can read their SMS consent history"
  on public.sms_consent_events
  for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "Admins can read SMS consent history" on public.sms_consent_events;
create policy "Admins can read SMS consent history"
  on public.sms_consent_events
  for select
  to authenticated
  using (public.is_admin());

create or replace function public.clear_sms_consent_when_phone_changes()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.phone is distinct from new.phone then
    if old.sms_transactional_opt_in then
      insert into public.sms_consent_events (
        user_id,
        phone,
        status,
        source,
        consent_version,
        consent_text
      ) values (
        old.id,
        old.phone,
        'opted_out',
        'phone_changed',
        coalesce(old.sms_transactional_consent_version, 'unknown'),
        coalesce(old.sms_transactional_consent_text, 'SMS consent cleared because the customer phone number changed.')
      );
    end if;
    new.sms_transactional_opt_in := false;
    new.sms_transactional_opted_in_at := null;
    new.sms_transactional_opted_out_at := case
      when old.sms_transactional_opt_in then now()
      else old.sms_transactional_opted_out_at
    end;
    new.sms_transactional_consent_source := null;
    new.sms_transactional_consent_version := null;
    new.sms_transactional_consent_text := null;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_clear_sms_consent_on_phone_change on public.profiles;
create trigger profiles_clear_sms_consent_on_phone_change
before update of phone on public.profiles
for each row
execute function public.clear_sms_consent_when_phone_changes();

create or replace function public.set_sms_transactional_preference(
  p_opt_in boolean,
  p_source text,
  p_consent_version text,
  p_consent_text text
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_opt_in boolean := coalesce(p_opt_in, false);
  v_source text := nullif(trim(p_source), '');
  v_version text := nullif(trim(p_consent_version), '');
  v_text text := nullif(trim(p_consent_text), '');
  v_should_log boolean := false;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if v_source is null or char_length(v_source) > 80 then
    raise exception 'A valid SMS consent source is required';
  end if;
  if v_version is null or char_length(v_version) > 80 then
    raise exception 'A valid SMS consent version is required';
  end if;
  if v_text is null or char_length(v_text) > 2000 then
    raise exception 'The SMS consent disclosure is required';
  end if;

  select *
    into v_profile
    from public.profiles
    where id = auth.uid()
    for update;

  if not found then
    raise exception 'Customer profile not found';
  end if;
  if v_opt_in and nullif(trim(v_profile.phone), '') is null then
    raise exception 'Add a mobile number before opting in to SMS';
  end if;

  v_should_log :=
    v_opt_in is distinct from v_profile.sms_transactional_opt_in
    or (
      v_opt_in
      and (
        v_source is distinct from v_profile.sms_transactional_consent_source
        or v_version is distinct from v_profile.sms_transactional_consent_version
        or v_text is distinct from v_profile.sms_transactional_consent_text
      )
    );

  if not v_opt_in and not v_profile.sms_transactional_opt_in then
    return v_profile;
  end if;

  update public.profiles
  set
    sms_transactional_opt_in = v_opt_in,
    sms_transactional_opted_in_at = case
      when v_opt_in and not sms_transactional_opt_in then now()
      else sms_transactional_opted_in_at
    end,
    sms_transactional_opted_out_at = case
      when v_opt_in then null
      when sms_transactional_opt_in then now()
      else sms_transactional_opted_out_at
    end,
    sms_transactional_consent_source = case when v_opt_in then v_source else sms_transactional_consent_source end,
    sms_transactional_consent_version = case when v_opt_in then v_version else sms_transactional_consent_version end,
    sms_transactional_consent_text = case when v_opt_in then v_text else sms_transactional_consent_text end
  where id = auth.uid()
  returning * into v_profile;

  if v_should_log then
    insert into public.sms_consent_events (
      user_id,
      phone,
      status,
      source,
      consent_version,
      consent_text
    ) values (
      v_profile.id,
      v_profile.phone,
      case when v_opt_in then 'opted_in' else 'opted_out' end,
      case when v_opt_in then v_source else coalesce(v_profile.sms_transactional_consent_source, v_source) end,
      case when v_opt_in then v_version else coalesce(v_profile.sms_transactional_consent_version, v_version) end,
      case when v_opt_in then v_text else coalesce(v_profile.sms_transactional_consent_text, v_text) end
    );
  end if;

  return v_profile;
end;
$$;

revoke all on function public.set_sms_transactional_preference(boolean, text, text, text) from public;
grant execute on function public.set_sms_transactional_preference(boolean, text, text, text) to authenticated;

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
