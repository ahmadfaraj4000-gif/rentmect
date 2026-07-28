-- Provider-isolated TollSpot intake, reconciliation, and charge handoff.
-- TollSpot's private field/signature contract belongs in the Edge adapter;
-- raw events remain replayable and no received toll automatically charges a customer.

create extension if not exists pgcrypto;

create table if not exists public.tollspot_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  provider_event_id text,
  event_type text,
  payload_sha256 text not null,
  payload jsonb not null,
  request_metadata jsonb not null default '{}'::jsonb,
  authentication_method text not null default 'shared_secret',
  status text not null default 'received'
    check (status in ('received', 'normalized', 'needs_review', 'processed', 'ignored', 'error')),
  processing_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

create index if not exists tollspot_webhook_events_status_idx
  on public.tollspot_webhook_events (status, received_at desc);

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

create index if not exists tollspot_vehicle_mappings_vehicle_idx
  on public.tollspot_vehicle_mappings (vehicle_id, active);

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
  status text not null default 'received'
    check (status in ('received', 'matched', 'charge_created', 'paid', 'disputed', 'ignored')),
  rental_charge_item_id uuid references public.rental_charge_items(id) on delete set null,
  raw_transaction jsonb not null default '{}'::jsonb,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists tollspot_transactions_review_idx
  on public.tollspot_transactions (status, occurred_at desc);
create index if not exists tollspot_transactions_rental_idx
  on public.tollspot_transactions (rental_id, occurred_at desc);

alter table public.tollspot_webhook_events enable row level security;
alter table public.tollspot_vehicle_mappings enable row level security;
alter table public.tollspot_transactions enable row level security;

drop policy if exists "Admins read TollSpot webhook events" on public.tollspot_webhook_events;
create policy "Admins read TollSpot webhook events"
on public.tollspot_webhook_events for select to authenticated using (public.is_admin());

drop policy if exists "Admins manage TollSpot vehicle mappings" on public.tollspot_vehicle_mappings;
create policy "Admins manage TollSpot vehicle mappings"
on public.tollspot_vehicle_mappings for all to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins read TollSpot transactions" on public.tollspot_transactions;
create policy "Admins read TollSpot transactions"
on public.tollspot_transactions for select to authenticated using (public.is_admin());

grant select on public.tollspot_webhook_events, public.tollspot_transactions to authenticated;
grant select, insert, update, delete on public.tollspot_vehicle_mappings to authenticated;
revoke insert, update, delete on public.tollspot_webhook_events, public.tollspot_transactions from anon, authenticated;

create or replace function public.admin_match_tollspot_transaction(
  p_transaction_id uuid,
  p_rental_id uuid
) returns public.tollspot_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_transaction from public.tollspot_transactions where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then
    raise exception 'This TollSpot transaction can no longer be rematched.';
  end if;
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if v_transaction.vehicle_id is not null and v_transaction.vehicle_id <> v_rental.vehicle_id then
    raise exception 'The selected rental belongs to a different vehicle.';
  end if;
  if (v_transaction.occurred_at at time zone 'America/New_York')::date
      not between v_rental.pickup_date and v_rental.return_date then
    raise exception 'The toll date is outside the selected rental period.';
  end if;

  update public.tollspot_transactions
  set vehicle_id = v_rental.vehicle_id, rental_id = v_rental.id, status = 'matched',
      reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = p_transaction_id returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.admin_match_tollspot_transaction(uuid, uuid) from public;
grant execute on function public.admin_match_tollspot_transaction(uuid, uuid) to authenticated;

create or replace function public.admin_create_tollspot_charge(
  p_transaction_id uuid,
  p_taxable boolean default false
) returns public.tollspot_transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_charge public.rental_charge_items%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_transaction from public.tollspot_transactions where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status <> 'matched' or v_transaction.rental_id is null then
    raise exception 'Review and match the toll to a rental before creating a customer charge.';
  end if;
  if v_transaction.rental_charge_item_id is not null then
    raise exception 'A customer charge already exists for this toll.';
  end if;

  select * into v_charge from public.admin_add_rental_charge(
    v_transaction.rental_id,
    coalesce(nullif(trim(v_transaction.road_or_plaza), ''), 'Toll charge'),
    'toll',
    v_transaction.total_amount,
    coalesce(p_taxable, false),
    concat_ws(' • ', nullif(trim(v_transaction.agency), ''), 'TollSpot transaction ' || v_transaction.tollspot_transaction_id)
  );

  update public.tollspot_transactions
  set status = 'charge_created', rental_charge_item_id = v_charge.id,
      reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = p_transaction_id returning * into v_transaction;
  return v_transaction;
end;
$$;

revoke all on function public.admin_create_tollspot_charge(uuid, boolean) from public;
grant execute on function public.admin_create_tollspot_charge(uuid, boolean) to authenticated;

comment on table public.tollspot_webhook_events is
  'Immutable provider intake used for deduplication, audit, replay, and future TollSpot payload mapping.';
comment on table public.tollspot_transactions is
  'Normalized tolls. Reception never auto-bills; an admin must match and create a pending rental charge.';
