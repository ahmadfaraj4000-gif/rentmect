-- Query title: Vehicle Deposits and Under-25 Pricing
-- Run after admin_audit_and_deposit_controls.sql and the active rental-creation migrations.

create table if not exists public.under_25_pricing_settings (
  id boolean primary key default true check (id),
  deposit_adjustment_enabled boolean not null default true,
  deposit_adjustment_type text not null default 'fixed'
    check (deposit_adjustment_type in ('fixed', 'percentage')),
  deposit_adjustment_value numeric(10,2) not null default 200
    check (deposit_adjustment_value >= 0 and deposit_adjustment_value <= 100000),
  rental_markup_percentage numeric(6,2) not null default 10
    check (rental_markup_percentage >= 0 and rental_markup_percentage <= 100),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.under_25_pricing_settings
  drop constraint if exists under_25_percentage_adjustment_range;
alter table public.under_25_pricing_settings
  add constraint under_25_percentage_adjustment_range check (
    deposit_adjustment_type <> 'percentage' or deposit_adjustment_value <= 100
  );

insert into public.under_25_pricing_settings (
  id, deposit_adjustment_enabled, deposit_adjustment_type,
  deposit_adjustment_value, rental_markup_percentage
) values (true, true, 'fixed', 200, 10)
on conflict (id) do nothing;

alter table public.under_25_pricing_settings enable row level security;

drop policy if exists "Authenticated users can read under 25 pricing" on public.under_25_pricing_settings;
create policy "Authenticated users can read under 25 pricing"
on public.under_25_pricing_settings for select to authenticated
using (true);

drop policy if exists "Admins can update under 25 pricing" on public.under_25_pricing_settings;
create policy "Admins can update under 25 pricing"
on public.under_25_pricing_settings for update to authenticated
using (public.is_admin()) with check (public.is_admin());

grant select on public.under_25_pricing_settings to authenticated;
grant update on public.under_25_pricing_settings to authenticated;

alter table public.vehicles
  alter column security_deposit set default 300;

alter table public.rentals
  add column if not exists base_rental_total numeric,
  add column if not exists under_25_markup_percentage numeric,
  add column if not exists under_25_markup_amount numeric,
  add column if not exists base_security_deposit numeric,
  add column if not exists under_25_deposit_adjustment_type text,
  add column if not exists under_25_deposit_adjustment_value numeric;

-- Apply the supplied per-vehicle refundable deposits by the fleet identifier at
-- the end of each vehicle name. Vehicles not listed retain their existing value.
with supplied_deposits(identifier, deposit) as (
  values
    ('224', 400::numeric), ('321', 400), ('YPS', 500), ('002', 300),
    ('158', 300), ('385', 300), ('473', 300), ('157', 300),
    ('677', 300), ('649', 300), ('418', 300), ('656', 300),
    ('451', 300), ('452', 300), ('210', 300), ('474', 300),
    ('149', 300), ('203', 300), ('225', 300), ('234', 300),
    ('997', 300), ('148', 300), ('650', 300), ('100', 400),
    ('191', 500)
)
update public.vehicles vehicles
set security_deposit = supplied_deposits.deposit
from supplied_deposits
where right(
  upper(regexp_replace(coalesce(vehicles.name, ''), '[^A-Za-z0-9]', '', 'g')),
  char_length(supplied_deposits.identifier)
) = supplied_deposits.identifier;

create or replace function public.rentmect_calculate_under25_deposit(
  p_base_deposit numeric
) returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_settings public.under_25_pricing_settings%rowtype;
  v_base numeric := greatest(coalesce(p_base_deposit, 0), 0);
begin
  select * into v_settings from public.under_25_pricing_settings where id = true;
  if not found or not coalesce(v_settings.deposit_adjustment_enabled, true) then
    return round(v_base, 2);
  end if;
  if v_settings.deposit_adjustment_type = 'percentage' then
    return round(v_base * (1 + v_settings.deposit_adjustment_value / 100), 2);
  end if;
  return round(v_base + v_settings.deposit_adjustment_value, 2);
end;
$$;

create or replace function public.rentmect_calculate_under25_rental(
  p_base_rental numeric
) returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_markup numeric := 10;
begin
  select rental_markup_percentage into v_markup
  from public.under_25_pricing_settings where id = true;
  return round(greatest(coalesce(p_base_rental, 0), 0) * (1 + coalesce(v_markup, 10) / 100), 2);
end;
$$;

revoke all on function public.rentmect_calculate_under25_deposit(numeric) from public;
revoke all on function public.rentmect_calculate_under25_rental(numeric) from public;
grant execute on function public.rentmect_calculate_under25_deposit(numeric) to authenticated, service_role;
grant execute on function public.rentmect_calculate_under25_rental(numeric) to authenticated, service_role;

create or replace function public.apply_rentmect_rental_pricing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_birth_date date;
  v_daily_rate numeric;
  v_vehicle_deposit numeric;
  v_days integer;
  v_base_rental numeric;
  v_under_25 boolean := false;
  v_settings public.under_25_pricing_settings%rowtype;
begin
  if tg_op = 'UPDATE' and lower(coalesce(old.payment_status, 'pending')) = 'paid' then
    return new;
  end if;

  select profiles.date_of_birth into v_birth_date
  from public.profiles profiles where profiles.id = new.user_id;
  select coalesce(vehicles.daily_rate, 0), coalesce(vehicles.security_deposit, 0)
    into v_daily_rate, v_vehicle_deposit
  from public.vehicles vehicles where vehicles.id = new.vehicle_id;

  if v_daily_rate is null then return new; end if;
  v_days := greatest(coalesce(new.return_date - new.pickup_date, 0), 0);
  v_base_rental := round(v_daily_rate * v_days, 2);
  v_under_25 := v_birth_date is not null
    and age((now() at time zone 'America/New_York')::date, v_birth_date) < interval '25 years';
  select * into v_settings from public.under_25_pricing_settings where id = true;

  new.base_rental_total := v_base_rental;
  new.rental_total := case when v_under_25
    then public.rentmect_calculate_under25_rental(v_base_rental)
    else v_base_rental end;
  new.under_25_markup_percentage := case when v_under_25
    then coalesce(v_settings.rental_markup_percentage, 10) else 0 end;
  new.under_25_markup_amount := round(new.rental_total - v_base_rental, 2);
  new.tax_amount := round(new.rental_total * 0.0635, 2);
  new.base_security_deposit := v_vehicle_deposit;
  new.security_deposit := case when v_under_25
    then public.rentmect_calculate_under25_deposit(v_vehicle_deposit)
    else v_vehicle_deposit end;
  new.under_25_deposit_adjustment_type := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_type, 'fixed')
    else null end;
  new.under_25_deposit_adjustment_value := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_value, 200)
    else 0 end;
  return new;
end;
$$;

drop trigger if exists rentals_enforce_age_deposit on public.rentals;
drop trigger if exists rentals_apply_rentmect_pricing on public.rentals;
create trigger rentals_apply_rentmect_pricing
before insert or update of user_id, vehicle_id, pickup_date, return_date
on public.rentals
for each row execute function public.apply_rentmect_rental_pricing();

create or replace function public.apply_rentmect_extension_age_markup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_markup numeric := 0;
begin
  if new.status = 'approved_pending_payment'
     and old.status is distinct from 'approved_pending_payment' then
    select coalesce(rentals.under_25_markup_percentage, 0) into v_markup
    from public.rentals rentals where rentals.id = new.rental_id;
    new.extension_rental_amount := round(coalesce(new.extension_rental_amount, 0) * (1 + v_markup / 100), 2);
    new.extension_tax_amount := round(new.extension_rental_amount * 0.0635, 2);
    new.extension_total_amount := new.extension_rental_amount
      + new.extension_tax_amount
      + coalesce(new.extension_deposit_amount, 0);
  end if;
  return new;
end;
$$;

drop trigger if exists rental_extensions_apply_age_markup on public.rental_extension_requests;
create trigger rental_extensions_apply_age_markup
before update of status, extension_rental_amount
on public.rental_extension_requests
for each row execute function public.apply_rentmect_extension_age_markup();

-- Correct unpaid rentals only. Paid rentals retain their original captured terms.
update public.rentals rentals
set user_id = rentals.user_id
where lower(coalesce(rentals.payment_status, 'pending')) <> 'paid'
  and rentals.user_id is not null
  and rentals.vehicle_id is not null;

-- Verification output shown in the SQL Editor after the migration completes.
select
  vehicles.name as vehicle,
  vehicles.security_deposit as age_25_plus_deposit,
  public.rentmect_calculate_under25_deposit(vehicles.security_deposit) as under_25_deposit,
  settings.deposit_adjustment_type,
  settings.deposit_adjustment_value,
  settings.rental_markup_percentage
from public.vehicles vehicles
cross join public.under_25_pricing_settings settings
where settings.id = true
order by vehicles.name;
