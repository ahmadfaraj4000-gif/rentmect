-- Staff audit trail, fixed age-tier deposits, and Stripe deposit-release state.
-- Run after the existing production RLS, rental workflow, Stripe, and promotion migrations.

create extension if not exists pgcrypto;

create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id) on delete set null,
  actor_email text,
  actor_role text,
  action text not null,
  entity_type text not null,
  entity_id text,
  changed_fields text[] not null default '{}',
  old_values jsonb,
  new_values jsonb,
  metadata jsonb not null default '{}'::jsonb,
  ip_address text,
  user_agent text,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_logs_created_at_idx
  on public.admin_audit_logs (created_at desc);
create index if not exists admin_audit_logs_actor_idx
  on public.admin_audit_logs (actor_user_id, created_at desc);
create index if not exists admin_audit_logs_entity_idx
  on public.admin_audit_logs (entity_type, entity_id, created_at desc);

alter table public.admin_audit_logs enable row level security;

drop policy if exists "Admins can read audit logs" on public.admin_audit_logs;
create policy "Admins can read audit logs"
on public.admin_audit_logs
for select
to authenticated
using (public.is_admin());

grant select on public.admin_audit_logs to authenticated;
revoke insert, update, delete on public.admin_audit_logs from anon, authenticated;

create or replace function public.rentmect_audit_snapshot(
  p_table_name text,
  p_row jsonb
) returns jsonb
language plpgsql
immutable
as $$
begin
  if p_row is null then return null; end if;

  -- Keep operational detail while excluding secrets, document locations, signed
  -- agreement bodies, Stripe customer identifiers, and private message content.
  return p_row - array[
    'agreement_snapshot',
    'agreement_hash',
    'agreement_ip',
    'agreement_user_agent',
    'drivers_license_number',
    'insurance_policy_number',
    'email',
    'phone',
    'address',
    'date_of_birth',
    'storage_path',
    'file_path',
    'photo_paths',
    'stripe_customer_id',
    'stripe_identity_verification_session_id',
    'identity_verification_error_code',
    'signature_data',
    'user_agent'
  ]::text[]
  - case when p_table_name = 'rental_messages' then 'message' else '__keep__' end;
end;
$$;

create or replace function public.capture_admin_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_raw jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_new_raw jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  v_old jsonb := public.rentmect_audit_snapshot(tg_table_name, v_old_raw);
  v_new jsonb := public.rentmect_audit_snapshot(tg_table_name, v_new_raw);
  v_actor_id uuid := auth.uid();
  v_actor_email text := nullif(auth.jwt() ->> 'email', '');
  v_actor_role text;
  v_changed_fields text[] := '{}';
  v_headers jsonb := '{}'::jsonb;
  v_entity_type text;
  v_entity_id text;
begin
  begin
    v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  if v_actor_id is not null then
    select coalesce(v_actor_email, profiles.email), profiles.role
      into v_actor_email, v_actor_role
      from public.profiles
      where profiles.id = v_actor_id;
  end if;

  -- The staff trail intentionally excludes ordinary customer self-service edits.
  if v_actor_id is not null and coalesce(v_actor_role, '') <> 'admin' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(field_name order by field_name), '{}')
      into v_changed_fields
      from (
        select jsonb_object_keys(coalesce(v_old_raw, '{}'::jsonb)) as field_name
        union
        select jsonb_object_keys(coalesce(v_new_raw, '{}'::jsonb)) as field_name
      ) fields
      where v_old_raw -> field_name is distinct from v_new_raw -> field_name;
  end if;

  v_entity_type := case tg_table_name
    when 'site_promotions' then 'promotion'
    when 'vehicles' then 'vehicle'
    when 'profiles' then 'customer_or_staff'
    when 'rentals' then 'rental'
    when 'discount_codes' then 'discount_code'
    when 'service_fees' then 'service_fee'
    when 'vehicle_availability_blocks' then 'availability_block'
    when 'rental_documents' then 'document'
    when 'vehicle_reports' then 'damage_case'
    when 'rental_return_inspections' then 'return_inspection'
    when 'rental_extension_requests' then 'extension_request'
    when 'rental_messages' then 'message'
    else tg_table_name
  end;
  v_entity_id := coalesce(v_new ->> 'id', v_old ->> 'id');

  insert into public.admin_audit_logs (
    actor_user_id,
    actor_email,
    actor_role,
    action,
    entity_type,
    entity_id,
    changed_fields,
    old_values,
    new_values,
    metadata,
    ip_address,
    user_agent
  ) values (
    v_actor_id,
    coalesce(v_actor_email, case when v_actor_id is null then 'system' else null end),
    coalesce(v_actor_role, case when v_actor_id is null then 'system' else 'authenticated' end),
    v_entity_type || '.' || lower(tg_op),
    v_entity_type,
    v_entity_id,
    v_changed_fields,
    v_old,
    v_new,
    jsonb_build_object('table', tg_table_name, 'database_operation', tg_op),
    coalesce(v_headers ->> 'cf-connecting-ip', v_headers ->> 'x-real-ip', v_headers ->> 'x-forwarded-for'),
    v_headers ->> 'user-agent'
  );

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.capture_admin_audit_log() from public;

create or replace function public.prevent_admin_audit_log_changes()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Admin audit records are immutable.';
end;
$$;

drop trigger if exists admin_audit_logs_immutable on public.admin_audit_logs;
create trigger admin_audit_logs_immutable
before update or delete on public.admin_audit_logs
for each row execute function public.prevent_admin_audit_log_changes();

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'site_promotions',
    'vehicles',
    'profiles',
    'rentals',
    'discount_codes',
    'service_fees',
    'vehicle_availability_blocks',
    'rental_documents',
    'vehicle_reports',
    'rental_return_inspections',
    'rental_extension_requests',
    'rental_messages'
  ] loop
    if to_regclass('public.' || v_table) is not null then
      execute format('drop trigger if exists rentmect_admin_audit on public.%I', v_table);
      execute format(
        'create trigger rentmect_admin_audit after insert or update or delete on public.%I for each row execute function public.capture_admin_audit_log()',
        v_table
      );
    end if;
  end loop;
end $$;

create or replace function public.record_admin_audit_event(
  p_action text,
  p_entity_type text default 'admin_session',
  p_entity_id text default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_role text;
  v_log_id uuid;
  v_headers jsonb := '{}'::jsonb;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if nullif(trim(p_action), '') is null then
    raise exception 'Audit action is required.';
  end if;

  select coalesce(v_email, profiles.email), profiles.role
    into v_email, v_role
    from public.profiles
    where profiles.id = v_admin_id;
  begin
    v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  insert into public.admin_audit_logs (
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id,
    metadata, ip_address, user_agent
  ) values (
    v_admin_id, v_email, coalesce(v_role, 'admin'), trim(p_action),
    coalesce(nullif(trim(p_entity_type), ''), 'admin_session'), p_entity_id,
    coalesce(p_metadata, '{}'::jsonb),
    coalesce(v_headers ->> 'cf-connecting-ip', v_headers ->> 'x-real-ip', v_headers ->> 'x-forwarded-for'),
    v_headers ->> 'user-agent'
  ) returning id into v_log_id;

  return v_log_id;
end;
$$;

revoke all on function public.record_admin_audit_event(text, text, text, jsonb) from public;
grant execute on function public.record_admin_audit_event(text, text, text, jsonb) to authenticated;

-- Deposit policy: $500 for renters under 25 and $300 for renters 25 or older.
alter table public.vehicles alter column security_deposit set default 300;
update public.vehicles set security_deposit = 300 where security_deposit is distinct from 300;

create or replace function public.enforce_rentmect_age_deposit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date_of_birth date;
begin
  if new.user_id is null then return new; end if;
  select profiles.date_of_birth into v_date_of_birth
    from public.profiles where profiles.id = new.user_id;
  if v_date_of_birth is null then return new; end if;
  new.security_deposit := case
    when age((now() at time zone 'America/New_York')::date, v_date_of_birth) < interval '25 years' then 500
    else 300
  end;
  return new;
end;
$$;

drop trigger if exists rentals_enforce_age_deposit on public.rentals;
create trigger rentals_enforce_age_deposit
before insert or update of user_id
on public.rentals
for each row execute function public.enforce_rentmect_age_deposit();

update public.rentals rentals
set security_deposit = case
  when age((now() at time zone 'America/New_York')::date, profiles.date_of_birth) < interval '25 years' then 500
  else 300
end
from public.profiles
where profiles.id = rentals.user_id
  and profiles.date_of_birth is not null
  and lower(coalesce(rentals.payment_status, 'pending')) <> 'paid'
  and rentals.security_deposit is distinct from case
    when age((now() at time zone 'America/New_York')::date, profiles.date_of_birth) < interval '25 years' then 500
    else 300
  end;

alter table public.rentals
  add column if not exists deposit_release_due_at timestamptz,
  add column if not exists deposit_release_attempted_at timestamptz,
  add column if not exists deposit_released_at timestamptz,
  add column if not exists deposit_refund_id text,
  add column if not exists deposit_release_reason text,
  add column if not exists deposit_release_error text;

drop index if exists public.rentals_deposit_release_due_idx;
create index rentals_deposit_release_due_idx
  on public.rentals (deposit_release_due_at)
  where deposit_status in ('held', 'adjustment_refund_due');

create or replace function public.schedule_rentmect_deposit_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_decision text;
begin
  if lower(coalesce(new.deposit_status, '')) in ('released', 'release_pending') then
    new.deposit_release_due_at := null;
    return new;
  end if;

  if lower(coalesce(new.deposit_status, '')) not in ('held', 'adjustment_refund_due') then
    new.deposit_release_due_at := null;
    return new;
  end if;

  if lower(coalesce(new.status, '')) = 'completed'
     and lower(coalesce(new.payment_provider, '')) = 'stripe'
     and lower(coalesce(old.status, '')) <> 'completed' then
    select inspections.deposit_decision
      into v_decision
      from public.rental_return_inspections inspections
      where inspections.rental_id = new.id
      order by inspections.created_at desc
      limit 1;

    if coalesce(v_decision, 'release') = 'release' then
      new.deposit_release_due_at := now() + interval '7 days';
      new.deposit_release_reason := 'Automatic release scheduled seven days after clean return completion.';
      new.deposit_release_error := null;
    else
      new.deposit_release_due_at := null;
      new.deposit_release_reason := 'Held by return inspection decision.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists rentals_schedule_deposit_release on public.rentals;
create trigger rentals_schedule_deposit_release
before update of status, deposit_status
on public.rentals
for each row execute function public.schedule_rentmect_deposit_release();

update public.rentals rentals
set deposit_release_due_at = coalesce((
      select inspections.created_at
      from public.rental_return_inspections inspections
      where inspections.rental_id = rentals.id
      order by inspections.created_at desc
      limit 1
    ), now()) + interval '7 days',
    deposit_release_reason = 'Automatic release scheduled seven days after clean return completion.'
where lower(coalesce(rentals.status, '')) = 'completed'
  and lower(coalesce(rentals.payment_provider, '')) = 'stripe'
  and lower(coalesce(rentals.deposit_status, '')) = 'held'
  and (
    select inspections.deposit_decision
    from public.rental_return_inspections inspections
    where inspections.rental_id = rentals.id
    order by inspections.created_at desc
    limit 1
  ) = 'release'
  and rentals.deposit_release_due_at is null;
