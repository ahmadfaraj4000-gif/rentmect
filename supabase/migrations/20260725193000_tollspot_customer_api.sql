-- TollSpot Customer API polling, fleet reconciliation, rental matching, and
-- admin-reviewed billing. Provider ingestion never bills a customer.

create extension if not exists pgcrypto;

alter table public.vehicles
  add column if not exists tollspot_enabled boolean not null default false,
  add column if not exists tollspot_vehicle_type text,
  add column if not exists plate_state text,
  add column if not exists plate_country text not null default 'US',
  add column if not exists plate_assigned_at timestamptz,
  add column if not exists model_year integer;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vehicles_tollspot_vehicle_type_check'
      and conrelid = 'public.vehicles'::regclass
  ) then
    alter table public.vehicles
      add constraint vehicles_tollspot_vehicle_type_check
      check (
        tollspot_vehicle_type is null
        or tollspot_vehicle_type in ('SEDAN', 'SUV', 'TRUCK', 'MOTORCYCLE', 'RV', 'TRAILER')
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'vehicles_model_year_check'
      and conrelid = 'public.vehicles'::regclass
  ) then
    alter table public.vehicles
      add constraint vehicles_model_year_check
      check (model_year is null or model_year between 1900 and 2200);
  end if;
end
$$;

create table if not exists public.tollspot_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  provider_event_id text,
  event_type text,
  payload_sha256 text not null,
  payload jsonb not null,
  request_metadata jsonb not null default '{}'::jsonb,
  authentication_method text not null default 'shared_secret',
  status text not null default 'received',
  processing_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

create table if not exists public.tollspot_vehicle_mappings (
  id uuid primary key default gen_random_uuid(),
  tollspot_vehicle_id text not null unique,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  provider_plate_snapshot text,
  provider_vin_snapshot text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tollspot_vehicle_mappings
  add column if not exists tollspot_license_plate_id text,
  add column if not exists tollspot_assignment_id text,
  add column if not exists provider_plate_state_snapshot text,
  add column if not exists provider_plate_country_snapshot text,
  add column if not exists provider_vehicle_type text,
  add column if not exists assignment_effective_at timestamptz,
  add column if not exists desired_provider_status text,
  add column if not exists sync_status text not null default 'pending',
  add column if not exists last_sync_attempt_at timestamptz,
  add column if not exists last_synced_at timestamptz,
  add column if not exists last_error_code text,
  add column if not exists last_error_message text;

alter table public.tollspot_vehicle_mappings
  drop constraint if exists tollspot_vehicle_mappings_sync_status_check;
alter table public.tollspot_vehicle_mappings
  add constraint tollspot_vehicle_mappings_sync_status_check
  check (sync_status in ('pending', 'synced', 'drifted', 'error', 'disabled'));

create unique index if not exists tollspot_vehicle_mappings_active_vehicle_uidx
  on public.tollspot_vehicle_mappings (vehicle_id) where active;

create table if not exists public.tollspot_plate_assignments (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  tollspot_vehicle_id text not null,
  tollspot_license_plate_id text not null,
  tollspot_assignment_id text not null unique,
  plate_number text not null,
  plate_state text,
  plate_country text,
  assigned_at timestamptz not null,
  removed_at timestamptz,
  active boolean generated always as (removed_at is null) stored,
  raw_assignment jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (removed_at is null or removed_at >= assigned_at)
);

create unique index if not exists tollspot_plate_assignments_active_vehicle_uidx
  on public.tollspot_plate_assignments (vehicle_id) where removed_at is null;
create index if not exists tollspot_plate_assignments_plate_time_idx
  on public.tollspot_plate_assignments (
    upper(plate_number),
    upper(coalesce(plate_state, '')),
    upper(coalesce(plate_country, '')),
    assigned_at,
    removed_at
  );

create table if not exists public.tollspot_sync_runs (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('health', 'sync_fleet', 'sync_tolls', 'backfill_tolls', 'run_all')),
  trigger_source text not null default 'admin'
    check (trigger_source in ('admin', 'schedule', 'system')),
  requested_by uuid references auth.users(id) on delete set null,
  status text not null default 'running'
    check (status in ('running', 'succeeded', 'partial', 'failed')),
  from_date date,
  to_date date,
  pages_processed integer not null default 0 check (pages_processed >= 0),
  records_received integer not null default 0 check (records_received >= 0),
  records_created integer not null default 0 check (records_created >= 0),
  records_updated integer not null default 0 check (records_updated >= 0),
  records_matched integer not null default 0 check (records_matched >= 0),
  records_needing_review integer not null default 0 check (records_needing_review >= 0),
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists tollspot_sync_runs_started_idx
  on public.tollspot_sync_runs (started_at desc);
create unique index if not exists tollspot_sync_runs_one_active_uidx
  on public.tollspot_sync_runs ((true))
  where status = 'running' and action in ('sync_tolls', 'backfill_tolls', 'run_all');

create table if not exists public.tollspot_transactions (
  id uuid primary key default gen_random_uuid(),
  webhook_event_id uuid references public.tollspot_webhook_events(id) on delete set null,
  tollspot_transaction_id text not null unique,
  tollspot_vehicle_id text,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  rental_id uuid references public.rentals(id) on delete set null,
  occurred_at timestamptz not null,
  posted_at timestamptz,
  agency text,
  road_or_plaza text,
  transponder_or_plate text,
  toll_amount numeric(10,2) not null check (toll_amount >= 0),
  admin_fee numeric(10,2) not null default 0 check (admin_fee >= 0),
  total_amount numeric(10,2) generated always as (round(toll_amount + admin_fee, 2)) stored,
  currency text not null default 'usd',
  status text not null default 'received',
  rental_charge_item_id uuid references public.rental_charge_items(id) on delete set null,
  raw_transaction jsonb not null default '{}'::jsonb,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tollspot_transactions
  add column if not exists entry_at timestamptz,
  add column if not exists entry_location text,
  add column if not exists exit_location text,
  add column if not exists transaction_type text,
  add column if not exists license_plate text,
  add column if not exists license_plate_state text,
  add column if not exists license_plate_country text,
  add column if not exists transponder_number text,
  add column if not exists host_id text,
  add column if not exists partner_vehicle_id text,
  add column if not exists vin_snapshot text,
  add column if not exists match_method text,
  add column if not exists match_candidate_count integer not null default 0,
  add column if not exists review_reason text,
  add column if not exists provider_updated_at timestamptz,
  add column if not exists ignored_reason text;

alter table public.tollspot_transactions
  drop constraint if exists tollspot_transactions_status_check;
alter table public.tollspot_transactions
  add constraint tollspot_transactions_status_check
  check (status in (
    'received', 'needs_review', 'matched', 'charge_created',
    'paid', 'disputed', 'ignored'
  ));

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'tollspot_transactions_type_check'
      and conrelid = 'public.tollspot_transactions'::regclass
  ) then
    alter table public.tollspot_transactions
      add constraint tollspot_transactions_type_check
      check (
        transaction_type is null
        or transaction_type in ('PARKING', 'TOLLS', 'VIOLATION')
      );
  end if;
end
$$;

create index if not exists tollspot_transactions_review_idx
  on public.tollspot_transactions (status, occurred_at desc);
create index if not exists tollspot_transactions_rental_idx
  on public.tollspot_transactions (rental_id, occurred_at desc);
create index if not exists tollspot_transactions_vehicle_time_idx
  on public.tollspot_transactions (vehicle_id, occurred_at desc);
create index if not exists tollspot_transactions_plate_time_idx
  on public.tollspot_transactions (
    upper(coalesce(license_plate, '')),
    upper(coalesce(license_plate_state, '')),
    upper(coalesce(license_plate_country, '')),
    occurred_at desc
  );

alter table public.tollspot_webhook_events enable row level security;
alter table public.tollspot_vehicle_mappings enable row level security;
alter table public.tollspot_plate_assignments enable row level security;
alter table public.tollspot_sync_runs enable row level security;
alter table public.tollspot_transactions enable row level security;

drop policy if exists "Admins read TollSpot webhook events" on public.tollspot_webhook_events;
create policy "Admins read TollSpot webhook events"
on public.tollspot_webhook_events for select to authenticated
using (public.is_admin());

drop policy if exists "Admins manage TollSpot vehicle mappings" on public.tollspot_vehicle_mappings;
create policy "Admins manage TollSpot vehicle mappings"
on public.tollspot_vehicle_mappings for select to authenticated
using (public.is_admin());

drop policy if exists "Admins read TollSpot plate assignments" on public.tollspot_plate_assignments;
create policy "Admins read TollSpot plate assignments"
on public.tollspot_plate_assignments for select to authenticated
using (public.is_admin());

drop policy if exists "Admins read TollSpot sync runs" on public.tollspot_sync_runs;
create policy "Admins read TollSpot sync runs"
on public.tollspot_sync_runs for select to authenticated
using (public.is_admin());

drop policy if exists "Admins read TollSpot transactions" on public.tollspot_transactions;
create policy "Admins read TollSpot transactions"
on public.tollspot_transactions for select to authenticated
using (public.is_admin());

grant select on public.tollspot_webhook_events, public.tollspot_vehicle_mappings,
  public.tollspot_plate_assignments, public.tollspot_sync_runs,
  public.tollspot_transactions to authenticated;
revoke insert, update, delete on public.tollspot_webhook_events,
  public.tollspot_vehicle_mappings, public.tollspot_plate_assignments,
  public.tollspot_sync_runs, public.tollspot_transactions
  from anon, authenticated;

create or replace function public.service_match_tollspot_transaction(
  p_transaction_id uuid
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_vehicle_id uuid;
  v_candidate_count integer := 0;
  v_rental_id uuid;
  v_match_method text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  select * into v_transaction
  from public.tollspot_transactions
  where id = p_transaction_id
  for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then
    return v_transaction;
  end if;

  select mappings.vehicle_id into v_vehicle_id
  from public.tollspot_vehicle_mappings mappings
  where mappings.active
    and mappings.tollspot_vehicle_id = v_transaction.tollspot_vehicle_id
  limit 1;

  if v_vehicle_id is not null then
    v_match_method := 'provider_vehicle_id';
  else
    select assignments.vehicle_id into v_vehicle_id
    from public.tollspot_plate_assignments assignments
    where upper(assignments.plate_number) = upper(coalesce(v_transaction.license_plate, ''))
      and (
        nullif(v_transaction.license_plate_state, '') is null
        or upper(coalesce(assignments.plate_state, '')) =
          upper(v_transaction.license_plate_state)
      )
      and (
        nullif(v_transaction.license_plate_country, '') is null
        or upper(coalesce(assignments.plate_country, '')) =
          upper(v_transaction.license_plate_country)
      )
      and v_transaction.occurred_at >= assignments.assigned_at
      and (
        assignments.removed_at is null
        or v_transaction.occurred_at < assignments.removed_at
      )
    order by assignments.assigned_at desc
    limit 1;
    if v_vehicle_id is not null then v_match_method := 'plate_assignment'; end if;
  end if;

  if v_vehicle_id is null then
    update public.tollspot_transactions
    set status = 'needs_review',
        match_method = null,
        match_candidate_count = 0,
        review_reason = 'No local vehicle mapping matched the provider charge.',
        updated_at = now()
    where id = p_transaction_id
    returning * into v_transaction;
    return v_transaction;
  end if;

  select count(*), min(rentals.id::text)::uuid
    into v_candidate_count, v_rental_id
  from public.rentals rentals
  where rentals.vehicle_id = v_vehicle_id
    and lower(coalesce(rentals.status, '')) <> 'cancelled'
    and rentals.pickup_date is not null
    and rentals.return_date is not null
    and v_transaction.occurred_at >=
      (public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time)
        at time zone 'America/New_York')
    and v_transaction.occurred_at <=
      (public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
        at time zone 'America/New_York');

  update public.tollspot_transactions
  set vehicle_id = v_vehicle_id,
      rental_id = case when v_candidate_count = 1 then v_rental_id else null end,
      status = case
        when v_candidate_count = 1 and coalesce(transaction_type, 'TOLLS') = 'TOLLS'
          then 'matched'
        else 'needs_review'
      end,
      match_method = v_match_method,
      match_candidate_count = v_candidate_count,
      review_reason = case
        when coalesce(transaction_type, 'TOLLS') <> 'TOLLS'
          then 'Parking and violation transactions require explicit review.'
        when v_candidate_count = 0
          then 'No rental interval contains the transaction occurrence time.'
        when v_candidate_count > 1
          then 'More than one rental interval contains the transaction occurrence time.'
        else null
      end,
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.service_match_tollspot_transaction(uuid) from public;
grant execute on function public.service_match_tollspot_transaction(uuid) to service_role;

create or replace function public.admin_match_tollspot_transaction(
  p_transaction_id uuid,
  p_rental_id uuid
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  select * into v_transaction
  from public.tollspot_transactions where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then
    raise exception 'This TollSpot transaction can no longer be rematched.';
  end if;
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if v_transaction.vehicle_id is not null
      and v_transaction.vehicle_id <> v_rental.vehicle_id then
    raise exception 'The selected rental belongs to a different vehicle.';
  end if;
  if v_transaction.occurred_at <
      (public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time)
        at time zone 'America/New_York')
      or v_transaction.occurred_at >
      (public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
        at time zone 'America/New_York') then
    raise exception 'The toll time is outside the selected rental period.';
  end if;

  update public.tollspot_transactions
  set vehicle_id = v_rental.vehicle_id,
      rental_id = v_rental.id,
      status = 'matched',
      match_method = 'admin',
      match_candidate_count = 1,
      review_reason = null,
      ignored_reason = null,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.admin_match_tollspot_transaction(uuid, uuid) from public;
grant execute on function public.admin_match_tollspot_transaction(uuid, uuid) to authenticated;

create or replace function public.admin_ignore_tollspot_transaction(
  p_transaction_id uuid,
  p_reason text
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 8 then
    raise exception 'Enter a specific reason of at least 8 characters.';
  end if;
  update public.tollspot_transactions
  set status = 'ignored',
      ignored_reason = trim(p_reason),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_transaction_id
    and status not in ('charge_created', 'paid')
  returning * into v_transaction;
  if not found then
    raise exception 'A charged or paid transaction cannot be ignored.';
  end if;
  return v_transaction;
end;
$$;

revoke all on function public.admin_ignore_tollspot_transaction(uuid, text) from public;
grant execute on function public.admin_ignore_tollspot_transaction(uuid, text) to authenticated;

create or replace function public.admin_create_tollspot_charge(
  p_transaction_id uuid,
  p_taxable boolean default false
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_charge public.rental_charge_items%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  select * into v_transaction
  from public.tollspot_transactions where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status <> 'matched' or v_transaction.rental_id is null then
    raise exception 'Review and match the toll to a rental before creating a customer charge.';
  end if;
  if v_transaction.rental_charge_item_id is not null then
    raise exception 'A customer charge already exists for this toll.';
  end if;

  select * into v_charge from public.admin_add_rental_charge(
    v_transaction.rental_id,
    coalesce(nullif(trim(v_transaction.exit_location), ''),
      nullif(trim(v_transaction.road_or_plaza), ''), 'Toll charge'),
    'toll',
    v_transaction.total_amount,
    coalesce(p_taxable, false),
    concat_ws(' • ', nullif(trim(v_transaction.agency), ''),
      'TollSpot transaction ' || v_transaction.tollspot_transaction_id)
  );

  update public.tollspot_transactions
  set status = 'charge_created',
      rental_charge_item_id = v_charge.id,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.admin_create_tollspot_charge(uuid, boolean) from public;
grant execute on function public.admin_create_tollspot_charge(uuid, boolean) to authenticated;

create or replace view public.admin_tollspot_transactions
with (security_invoker = true)
as
select
  transactions.id,
  transactions.tollspot_transaction_id,
  transactions.tollspot_vehicle_id,
  transactions.vehicle_id,
  transactions.rental_id,
  transactions.occurred_at,
  transactions.posted_at,
  transactions.entry_at,
  transactions.entry_location,
  transactions.exit_location,
  transactions.agency,
  transactions.transaction_type,
  transactions.license_plate,
  transactions.license_plate_state,
  transactions.license_plate_country,
  case
    when nullif(transactions.transponder_number, '') is null then null
    else repeat('•', greatest(length(transactions.transponder_number) - 4, 0))
      || right(transactions.transponder_number, 4)
  end as masked_transponder,
  transactions.toll_amount,
  transactions.admin_fee,
  transactions.total_amount,
  transactions.currency,
  transactions.status,
  transactions.match_method,
  transactions.match_candidate_count,
  transactions.review_reason,
  transactions.ignored_reason,
  transactions.rental_charge_item_id,
  transactions.reviewed_by,
  transactions.reviewed_at,
  transactions.created_at,
  transactions.updated_at
from public.tollspot_transactions transactions;

grant select on public.admin_tollspot_transactions to authenticated;

comment on table public.tollspot_sync_runs is
  'Sanitized operational history for TollSpot API health, fleet, and charge synchronization.';
comment on table public.tollspot_transactions is
  'Normalized TollSpot charges. Ingestion and matching never create a customer charge.';
