-- Automated TollSpot billing, charge-gated deposit release, and authoritative
-- customer discount pricing.
--
-- Run after:
--   20260725193000_tollspot_customer_api.sql
--   rental_billing_and_completion.sql
--   deposit_carryover_and_emergency_exceptions.sql
--   site_promotions.sql

create table if not exists public.billing_automation_settings (
  id boolean primary key default true check (id),
  automatic_deposit_release_enabled boolean not null default true,
  deposit_release_delay_days integer not null default 7
    check (deposit_release_delay_days between 1 and 30),
  tollspot_automatic_sync_enabled boolean not null default true,
  tollspot_auto_create_charges boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

insert into public.billing_automation_settings (id)
values (true)
on conflict (id) do nothing;

alter table public.billing_automation_settings enable row level security;
drop policy if exists "Admins read billing automation settings" on public.billing_automation_settings;
create policy "Admins read billing automation settings"
on public.billing_automation_settings for select to authenticated
using (public.is_admin());
drop policy if exists "Admins update billing automation settings" on public.billing_automation_settings;
create policy "Admins update billing automation settings"
on public.billing_automation_settings for update to authenticated
using (public.is_admin()) with check (public.is_admin());
grant select, update on public.billing_automation_settings to authenticated;

create or replace function public.enforce_minimum_renter_age()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_birth_date date;
begin
  select date_of_birth into v_birth_date
  from public.profiles where id = new.user_id;
  if v_birth_date is null then
    raise exception 'A valid date of birth is required before booking.';
  end if;
  if age((now() at time zone 'America/New_York')::date, v_birth_date) < interval '21 years' then
    raise exception 'Renters must be at least 21 years old.';
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_enforce_minimum_renter_age on public.rentals;
create trigger rentals_enforce_minimum_renter_age
before insert or update of user_id on public.rentals
for each row execute function public.enforce_minimum_renter_age();

-- Every real fleet vehicle participates in TollSpot. The internal checkout test
-- vehicle is the only exception.
alter table public.vehicles
  alter column tollspot_enabled set default true,
  alter column plate_state set default 'CT',
  alter column plate_country set default 'US';

update public.vehicles
set tollspot_enabled = id <> '00000000-0000-4000-8000-000000000015'::uuid,
    plate_state = coalesce(nullif(upper(trim(plate_state)), ''), 'CT'),
    plate_country = coalesce(nullif(upper(trim(plate_country)), ''), 'US'),
    plate_assigned_at = coalesce(plate_assigned_at, created_at),
    tollspot_vehicle_type = coalesce(
      tollspot_vehicle_type,
      case
        when upper(coalesce(vehicle_type, '') || ' ' || coalesce(name, '')) like '%TRUCK%' then 'TRUCK'
        when upper(coalesce(vehicle_type, '') || ' ' || coalesce(name, '')) like '%VAN%' then 'SUV'
        when upper(coalesce(vehicle_type, '') || ' ' || coalesce(name, '')) like '%SUV%' then 'SUV'
        else 'SEDAN'
      end
    );

create or replace function public.enforce_tollspot_for_real_fleet()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.tollspot_enabled := new.id <> '00000000-0000-4000-8000-000000000015'::uuid;
  if new.tollspot_enabled then
    new.plate_state := coalesce(nullif(upper(trim(new.plate_state)), ''), 'CT');
    new.plate_country := coalesce(nullif(upper(trim(new.plate_country)), ''), 'US');
    new.plate_assigned_at := coalesce(new.plate_assigned_at, new.created_at, now());
    new.tollspot_vehicle_type := coalesce(
      new.tollspot_vehicle_type,
      case
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%TRUCK%' then 'TRUCK'
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%VAN%' then 'SUV'
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%SUV%' then 'SUV'
        else 'SEDAN'
      end
    );
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_enforce_tollspot_enrollment on public.vehicles;
create trigger vehicles_enforce_tollspot_enrollment
before insert or update on public.vehicles
for each row execute function public.enforce_tollspot_for_real_fleet();

-- Provider source identifiers make automatic charge creation idempotent even
-- when TollSpot returns the same transaction in many polling windows.
alter table public.rental_charge_items
  add column if not exists source_type text,
  add column if not exists source_reference text;

create unique index if not exists rental_charge_items_source_uidx
on public.rental_charge_items (source_type, source_reference)
where source_type is not null and source_reference is not null;

create or replace function public.service_create_tollspot_charge(
  p_transaction_id uuid
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_auto_create boolean := true;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  select * into v_transaction
  from public.tollspot_transactions
  where id = p_transaction_id
  for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.rental_charge_item_id is not null
     or v_transaction.status in ('charge_created', 'paid') then
    return v_transaction;
  end if;
  if v_transaction.status <> 'matched'
     or v_transaction.rental_id is null
     or coalesce(v_transaction.transaction_type, 'TOLLS') <> 'TOLLS' then
    return v_transaction;
  end if;

  select tollspot_auto_create_charges into v_auto_create
  from public.billing_automation_settings where id = true;
  if not coalesce(v_auto_create, true) then return v_transaction; end if;

  select * into v_rental
  from public.rentals
  where id = v_transaction.rental_id
  for update;
  if not found or lower(coalesce(v_rental.status, '')) = 'cancelled' then
    update public.tollspot_transactions
    set status = 'needs_review',
        review_reason = 'The matched rental is unavailable for billing.',
        updated_at = now()
    where id = v_transaction.id
    returning * into v_transaction;
    return v_transaction;
  end if;

  insert into public.rental_charge_items (
    rental_id, user_id, name, charge_type, description, amount, taxable,
    tax_amount, total_amount, included_in_initial_payment, status,
    created_by, source_type, source_reference
  ) values (
    v_rental.id,
    v_rental.user_id,
    coalesce(
      nullif(trim(v_transaction.exit_location), ''),
      nullif(trim(v_transaction.road_or_plaza), ''),
      'Toll charge'
    ),
    'toll',
    concat_ws(
      ' • ',
      nullif(trim(v_transaction.agency), ''),
      'TollSpot transaction ' || v_transaction.tollspot_transaction_id
    ),
    round(v_transaction.total_amount, 2),
    false,
    0,
    round(v_transaction.total_amount, 2),
    false,
    'pending',
    null,
    'tollspot',
    v_transaction.tollspot_transaction_id
  )
  on conflict (source_type, source_reference)
    where source_type is not null and source_reference is not null
  do update set updated_at = now()
  returning * into v_charge;

  update public.tollspot_transactions
  set status = 'charge_created',
      rental_charge_item_id = v_charge.id,
      reviewed_by = null,
      reviewed_at = now(),
      review_reason = null,
      updated_at = now()
  where id = v_transaction.id
  returning * into v_transaction;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id,
    v_rental.user_id,
    null,
    'tollspot_charge_automatically_added',
    jsonb_build_object(
      'charge_id', v_charge.id,
      'tollspot_transaction_id', v_transaction.tollspot_transaction_id,
      'vehicle_id', v_transaction.vehicle_id,
      'amount', v_charge.total_amount
    )
  );
  return v_transaction;
end;
$$;

revoke all on function public.service_create_tollspot_charge(uuid) from public;
grant execute on function public.service_create_tollspot_charge(uuid) to service_role;

-- Deterministic matches now create the rental charge immediately. Ambiguous,
-- parking, and violation records remain in the exception queue.
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
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  select * into v_transaction from public.tollspot_transactions
  where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then return v_transaction; end if;

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
      and (nullif(v_transaction.license_plate_state, '') is null
        or upper(coalesce(assignments.plate_state, '')) = upper(v_transaction.license_plate_state))
      and (nullif(v_transaction.license_plate_country, '') is null
        or upper(coalesce(assignments.plate_country, '')) = upper(v_transaction.license_plate_country))
      and v_transaction.occurred_at >= assignments.assigned_at
      and (assignments.removed_at is null or v_transaction.occurred_at < assignments.removed_at)
    order by assignments.assigned_at desc
    limit 1;
    if v_vehicle_id is not null then v_match_method := 'plate_assignment'; end if;
  end if;

  if v_vehicle_id is null then
    update public.tollspot_transactions
    set status = 'needs_review', vehicle_id = null, rental_id = null,
        match_method = null, match_candidate_count = 0,
        review_reason = 'No local vehicle mapping matched the provider charge.',
        updated_at = now()
    where id = p_transaction_id returning * into v_transaction;
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

  if v_transaction.status = 'matched' then
    return public.service_create_tollspot_charge(v_transaction.id);
  end if;
  return v_transaction;
end;
$$;

revoke all on function public.service_match_tollspot_transaction(uuid) from public;
grant execute on function public.service_match_tollspot_transaction(uuid) to service_role;

create or replace function public.sync_tollspot_transaction_from_charge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.source_type, '') <> 'tollspot'
     or old.status is not distinct from new.status then
    return new;
  end if;
  if new.status = 'paid' then
    update public.tollspot_transactions
    set status = 'paid', updated_at = now()
    where rental_charge_item_id = new.id;
  elsif new.status = 'waived' then
    update public.tollspot_transactions
    set status = 'ignored',
        ignored_reason = 'Linked customer charge was waived by an administrator.',
        updated_at = now()
    where rental_charge_item_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists rental_charges_sync_tollspot_status on public.rental_charge_items;
create trigger rental_charges_sync_tollspot_status
after update of status on public.rental_charge_items
for each row execute function public.sync_tollspot_transaction_from_charge();

-- Deposit refunds are never allowed while a post-booking balance is still due.
create or replace function public.rentmect_unpaid_charge_total(
  p_rental_id uuid
) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(total_amount), 0)
  from public.rental_charge_items
  where rental_id = p_rental_id
    and not included_in_initial_payment
    and status in ('pending', 'checkout_open', 'failed');
$$;

revoke all on function public.rentmect_unpaid_charge_total(uuid) from public;
grant execute on function public.rentmect_unpaid_charge_total(uuid) to authenticated, service_role;

create or replace function public.schedule_rentmect_deposit_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_decision text;
  v_enabled boolean := true;
  v_delay integer := 7;
begin
  if lower(coalesce(new.deposit_status, '')) in ('released', 'release_pending')
     or lower(coalesce(new.deposit_status, '')) not in ('held', 'adjustment_refund_due') then
    new.deposit_release_due_at := null;
    return new;
  end if;

  select automatic_deposit_release_enabled, deposit_release_delay_days
  into v_enabled, v_delay
  from public.billing_automation_settings where id = true;

  if lower(coalesce(new.status, '')) = 'completed'
     and lower(coalesce(new.payment_provider, '')) = 'stripe'
     and lower(coalesce(old.status, '')) <> 'completed' then
    select inspections.deposit_decision into v_decision
    from public.rental_return_inspections inspections
    where inspections.rental_id = new.id
    order by inspections.created_at desc limit 1;

    if coalesce(v_decision, 'release') = 'release' and coalesce(v_enabled, true) then
      new.deposit_release_due_at := now() + make_interval(days => coalesce(v_delay, 7));
      new.deposit_release_reason := format(
        'Automatic release scheduled %s days after clean return; unpaid rental charges block release.',
        coalesce(v_delay, 7)
      );
      new.deposit_release_error := null;
    else
      new.deposit_release_due_at := null;
      new.deposit_release_reason := case
        when not coalesce(v_enabled, true) then 'Automatic deposit release is disabled in Billing Automation settings.'
        else 'Held by return inspection decision.'
      end;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.apply_billing_automation_to_held_deposits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.automatic_deposit_release_enabled then
    update public.rentals rentals
    set deposit_release_due_at = now() + make_interval(days => new.deposit_release_delay_days),
        deposit_release_reason = format(
          'Automatic release scheduled %s days after Billing Automation was enabled; unpaid rental charges block release.',
          new.deposit_release_delay_days
        ),
        deposit_release_error = null
    where lower(coalesce(rentals.status, '')) = 'completed'
      and lower(coalesce(rentals.payment_provider, '')) = 'stripe'
      and lower(coalesce(rentals.deposit_status, '')) in ('held', 'adjustment_refund_due')
      and coalesce((
        select inspections.deposit_decision
        from public.rental_return_inspections inspections
        where inspections.rental_id = rentals.id
        order by inspections.created_at desc
        limit 1
      ), 'release') = 'release';
  else
    update public.rentals rentals
    set deposit_release_due_at = null,
        deposit_release_reason = 'Automatic deposit release is disabled in Billing Automation settings.'
    where lower(coalesce(rentals.deposit_status, '')) in ('held', 'adjustment_refund_due')
      and rentals.deposit_release_due_at is not null;
  end if;
  return new;
end;
$$;

drop trigger if exists billing_automation_reschedule_deposits on public.billing_automation_settings;
create trigger billing_automation_reschedule_deposits
after update of automatic_deposit_release_enabled, deposit_release_delay_days
on public.billing_automation_settings
for each row execute function public.apply_billing_automation_to_held_deposits();

-- Local/external deposit returns receive the same balance-due protection.
create or replace function public.admin_record_local_deposit_release(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_released numeric := 0;
  v_remaining numeric := 0;
  v_unpaid numeric := 0;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) <> 'completed' then
    raise exception 'The deposit can be returned only after the rental is completed.';
  end if;
  v_unpaid := public.rentmect_unpaid_charge_total(v_rental.id);
  if v_unpaid > 0 then
    raise exception 'Collect or waive the outstanding rental charges (%) before returning the deposit.',
      to_char(v_unpaid, 'FM$999,999,990.00');
  end if;

  perform public.ensure_rental_deposit_allocation(v_rental.id);
  select coalesce(sum(amount_held - amount_released), 0) into v_released
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');
  if v_released <= 0 then raise exception 'No externally held deposit allocation remains.'; end if;

  update public.rental_deposit_allocations
  set amount_released = amount_held, status = 'released', last_error = null, updated_at = now()
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');

  select coalesce(sum(amount_held - amount_released), 0) into v_remaining
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id and status <> 'released';

  update public.rentals
  set deposit_held_amount = v_remaining,
      deposit_released_amount = coalesce(deposit_released_amount, 0) + v_released,
      deposit_status = case when v_remaining <= 0 then 'released' else deposit_status end,
      deposit_released_at = case when v_remaining <= 0 then now() else deposit_released_at end,
      deposit_release_reason = 'External deposit return recorded by authorized admin.',
      deposit_decrease_refund_due = case when v_remaining <= 0 then 0 else deposit_decrease_refund_due end,
      updated_at = now()
  where id = v_rental.id returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_local_deposit_release_recorded',
    jsonb_build_object('amount', v_released));
  return v_rental;
end;
$$;

revoke all on function public.admin_record_local_deposit_release(uuid) from public;
grant execute on function public.admin_record_local_deposit_release(uuid) to authenticated;

-- Discounts are attached to a rental before payment and snapshotted. They
-- reduce rental price and its tax, never the refundable deposit.
alter table public.rentals
  add column if not exists pre_discount_rental_total numeric,
  add column if not exists discount_code_id uuid references public.discount_codes(id) on delete set null,
  add column if not exists discount_code text,
  add column if not exists discount_amount numeric not null default 0
    check (discount_amount >= 0),
  add column if not exists discount_reserved boolean not null default false;

create or replace function public.apply_customer_discount_to_rental(
  p_rental_id uuid,
  p_code text
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_code public.discount_codes%rowtype;
  v_before numeric;
  v_discount numeric;
begin
  if v_user_id is null then raise exception 'Sign in to apply a discount code.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if v_rental.user_id <> v_user_id and not public.is_admin() then raise exception 'This rental does not belong to you.'; end if;
  if lower(coalesce(v_rental.payment_status, 'pending')) = 'paid' then raise exception 'A paid rental cannot be repriced.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then raise exception 'A cancelled rental cannot be repriced.'; end if;
  if v_rental.discount_reserved then return v_rental; end if;

  select * into v_code
  from public.discount_codes
  where lower(code) = lower(trim(p_code))
  for update;
  if not found or not v_code.active then raise exception 'That discount code is not active.'; end if;
  if v_code.starts_at is not null and current_date < v_code.starts_at then raise exception 'That discount code has not started yet.'; end if;
  if v_code.expires_at is not null and current_date > v_code.expires_at then raise exception 'That discount code has expired.'; end if;
  if v_code.max_redemptions is not null and v_code.redemption_count >= v_code.max_redemptions then
    raise exception 'That discount code has reached its usage limit.';
  end if;

  v_before := greatest(coalesce(v_rental.rental_total, 0), 0);
  v_discount := case
    when v_code.discount_type = 'percentage' then round(v_before * v_code.amount / 100, 2)
    else least(round(v_code.amount, 2), v_before)
  end;

  update public.discount_codes
  set redemption_count = redemption_count + 1, updated_at = now()
  where id = v_code.id;

  update public.rentals
  set pre_discount_rental_total = v_before,
      discount_code_id = v_code.id,
      discount_code = upper(v_code.code),
      discount_amount = v_discount,
      discount_reserved = true,
      rental_total = round(v_before - v_discount, 2),
      tax_amount = round((v_before - v_discount + coalesce(taxable_service_fee_total, 0)) * 0.0635, 2),
      updated_at = now()
  where id = v_rental.id
  returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_user_id, 'discount_applied',
    jsonb_build_object('code', v_rental.discount_code, 'amount', v_discount));
  return v_rental;
end;
$$;

revoke all on function public.apply_customer_discount_to_rental(uuid, text) from public;
grant execute on function public.apply_customer_discount_to_rental(uuid, text) to authenticated;

create or replace function public.reprice_reserved_rental_discount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code public.discount_codes%rowtype;
  v_before numeric;
  v_discount numeric;
begin
  if not coalesce(new.discount_reserved, false) or new.discount_code_id is null then
    return new;
  end if;
  select * into v_code from public.discount_codes where id = new.discount_code_id;
  if not found then return new; end if;
  v_before := greatest(coalesce(new.rental_total, 0), 0);
  v_discount := case
    when v_code.discount_type = 'percentage' then round(v_before * v_code.amount / 100, 2)
    else least(round(v_code.amount, 2), v_before)
  end;
  update public.rentals
  set pre_discount_rental_total = v_before,
      discount_amount = v_discount,
      rental_total = round(v_before - v_discount, 2),
      tax_amount = round((v_before - v_discount + coalesce(new.taxable_service_fee_total, 0)) * 0.0635, 2),
      updated_at = now()
  where id = new.id;
  return new;
end;
$$;

drop trigger if exists rentals_reprice_reserved_discount on public.rentals;
create trigger rentals_reprice_reserved_discount
after update of user_id, vehicle_id, pickup_date, return_date
on public.rentals
for each row execute function public.reprice_reserved_rental_discount();

create or replace function public.release_cancelled_rental_discount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled'
     and coalesce(new.discount_reserved, false)
     and lower(coalesce(new.payment_status, 'pending')) <> 'paid'
     and new.discount_code_id is not null then
    update public.discount_codes
    set redemption_count = greatest(redemption_count - 1, 0), updated_at = now()
    where id = new.discount_code_id;
    new.discount_reserved := false;
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_release_cancelled_discount on public.rentals;
create trigger rentals_release_cancelled_discount
before update of status on public.rentals
for each row execute function public.release_cancelled_rental_discount();

-- Promotions must point at a real discount code so advertised savings always
-- match customer billing.
alter table public.site_promotions
  add column if not exists discount_code_id uuid references public.discount_codes(id) on delete restrict;

update public.site_promotions promotions
set discount_code_id = codes.id
from public.discount_codes codes
where lower(codes.code) = lower(promotions.coupon_code)
  and promotions.discount_code_id is null;

create or replace function public.validate_site_promotion_discount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code public.discount_codes%rowtype;
begin
  select * into v_code
  from public.discount_codes
  where id = new.discount_code_id
     or lower(code) = lower(trim(new.coupon_code))
  order by (id = new.discount_code_id) desc
  limit 1;
  if not found then raise exception 'Choose a saved discount code for this promotion.'; end if;
  if not v_code.active then raise exception 'Activate the discount code before publishing this promotion.'; end if;
  new.discount_code_id := v_code.id;
  new.coupon_code := upper(v_code.code);
  return new;
end;
$$;

drop trigger if exists site_promotions_validate_discount on public.site_promotions;
create trigger site_promotions_validate_discount
before insert or update of coupon_code, discount_code_id, active
on public.site_promotions
for each row execute function public.validate_site_promotion_discount();

comment on table public.billing_automation_settings is
  'Admin-controlled automation for TollSpot polling/charge creation and charge-gated deposit release.';
comment on function public.service_match_tollspot_transaction(uuid) is
  'Matches a TollSpot transaction to vehicle and rental and automatically creates an idempotent customer charge when deterministic.';
