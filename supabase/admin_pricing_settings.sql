create table if not exists public.discount_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  discount_type text not null check (discount_type in ('percentage', 'fixed')),
  amount numeric(10,2) not null check (amount > 0),
  max_redemptions integer check (max_redemptions is null or max_redemptions > 0),
  redemption_count integer not null default 0 check (redemption_count >= 0),
  starts_at date,
  expires_at date,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (discount_type <> 'percentage' or amount <= 100),
  check (expires_at is null or starts_at is null or expires_at >= starts_at)
);

create unique index if not exists discount_codes_code_key
  on public.discount_codes (lower(code));

create table if not exists public.service_fees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  service_type text not null,
  amount numeric(10,2) not null check (amount > 0),
  taxable boolean not null default true,
  active boolean not null default true,
  description text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.service_fees
  drop constraint if exists service_fees_service_type_check;

create table if not exists public.vehicle_availability_blocks (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  start_date date not null,
  end_date date not null,
  start_time text not null default '9:00 AM',
  end_time text not null default '9:00 AM',
  block_type text not null default 'unavailable',
  label text not null default 'Unavailable',
  notes text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);

alter table public.vehicles
  add column if not exists description text,
  add column if not exists features text[] not null default '{}',
  add column if not exists image_urls text[] not null default '{}';

create or replace function public.set_admin_pricing_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_discount_codes_updated_at on public.discount_codes;
create trigger set_discount_codes_updated_at
before update on public.discount_codes
for each row execute function public.set_admin_pricing_updated_at();

drop trigger if exists set_service_fees_updated_at on public.service_fees;
create trigger set_service_fees_updated_at
before update on public.service_fees
for each row execute function public.set_admin_pricing_updated_at();

drop trigger if exists set_vehicle_availability_blocks_updated_at on public.vehicle_availability_blocks;
create trigger set_vehicle_availability_blocks_updated_at
before update on public.vehicle_availability_blocks
for each row execute function public.set_admin_pricing_updated_at();

alter table public.discount_codes enable row level security;
alter table public.service_fees enable row level security;
alter table public.vehicle_availability_blocks enable row level security;

drop policy if exists "Admins can read discount codes" on public.discount_codes;
create policy "Admins can read discount codes"
on public.discount_codes
for select
to authenticated
using (public.is_admin());

drop policy if exists "Admins can create discount codes" on public.discount_codes;
create policy "Admins can create discount codes"
on public.discount_codes
for insert
to authenticated
with check (public.is_admin());

drop policy if exists "Admins can update discount codes" on public.discount_codes;
create policy "Admins can update discount codes"
on public.discount_codes
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins can delete discount codes" on public.discount_codes;
create policy "Admins can delete discount codes"
on public.discount_codes
for delete
to authenticated
using (public.is_admin());

drop policy if exists "Admins can read service fees" on public.service_fees;
create policy "Admins can read service fees"
on public.service_fees
for select
to authenticated
using (public.is_admin());

drop policy if exists "Authenticated users can read active service fees" on public.service_fees;
create policy "Authenticated users can read active service fees"
on public.service_fees
for select
to authenticated
using (active = true);

drop policy if exists "Admins can create service fees" on public.service_fees;
create policy "Admins can create service fees"
on public.service_fees
for insert
to authenticated
with check (public.is_admin());

drop policy if exists "Admins can update service fees" on public.service_fees;
create policy "Admins can update service fees"
on public.service_fees
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins can delete service fees" on public.service_fees;
create policy "Admins can delete service fees"
on public.service_fees
for delete
to authenticated
using (public.is_admin());

drop policy if exists "Admins can read vehicle availability blocks" on public.vehicle_availability_blocks;
create policy "Admins can read vehicle availability blocks"
on public.vehicle_availability_blocks
for select
to authenticated
using (public.is_admin());

drop policy if exists "Admins can create vehicle availability blocks" on public.vehicle_availability_blocks;
create policy "Admins can create vehicle availability blocks"
on public.vehicle_availability_blocks
for insert
to authenticated
with check (public.is_admin());

drop policy if exists "Admins can update vehicle availability blocks" on public.vehicle_availability_blocks;
create policy "Admins can update vehicle availability blocks"
on public.vehicle_availability_blocks
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins can delete vehicle availability blocks" on public.vehicle_availability_blocks;
create policy "Admins can delete vehicle availability blocks"
on public.vehicle_availability_blocks
for delete
to authenticated
using (public.is_admin());

create or replace function public.sign_rental_agreement(
  p_rental_id uuid,
  p_signature_name text,
  p_agreement_version text,
  p_agreement_snapshot text,
  p_agreement_hash text,
  p_user_agent text default null,
  p_signature_data text default null
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
    coalesce(nullif(p_signature_data, ''), 'Typed signature: ' || trim(p_signature_name)),
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
      'ip_address', v_ip,
      'drawn_signature', p_signature_data is not null and p_signature_data <> ''
    )
  );

  return v_rental;
end;
$$;

grant execute on function public.sign_rental_agreement(uuid, text, text, text, text, text, text) to authenticated;
