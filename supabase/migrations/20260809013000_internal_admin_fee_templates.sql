begin;

-- service_fees is an admin-owned catalog of optional post-booking charges.
-- A row being active means it is available for an admin to apply to one
-- specific rental; it must never affect a public quote or a new reservation.
drop policy if exists "Authenticated users can read active service fees" on public.service_fees;

comment on table public.service_fees is
  'Internal admin charge templates. Never included automatically in public quotes, checkout, or new rentals.';

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
  new.service_fee_total := 0;
  new.taxable_service_fee_total := 0;
  new.service_fee_tax_amount := 0;
  new.tax_amount := round(new.rental_total * 0.0635, 2);
  new.base_security_deposit := v_vehicle_deposit;
  new.security_deposit := case when v_under_25
    then public.rentmect_calculate_under25_deposit(v_vehicle_deposit)
    else v_vehicle_deposit end;
  new.under_25_deposit_adjustment_type := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_type, 'fixed') else null end;
  new.under_25_deposit_adjustment_value := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_value, 200) else 0 end;
  return new;
end;
$$;

drop trigger if exists rentals_snapshot_service_fees on public.rentals;

-- Repair only unpaid reservations that inherited internal templates. Paid
-- rental history remains immutable and auditable.
delete from public.rental_charge_items charge
using public.rentals rental
where charge.rental_id = rental.id
  and charge.included_in_initial_payment = true
  and lower(coalesce(rental.payment_status, 'pending')) <> 'paid';

update public.rentals
set service_fee_total = 0,
    taxable_service_fee_total = 0,
    service_fee_tax_amount = 0,
    tax_amount = round(coalesce(rental_total, 0) * 0.0635, 2),
    updated_at = now()
where lower(coalesce(payment_status, 'pending')) <> 'paid'
  and (
    coalesce(service_fee_total, 0) <> 0
    or coalesce(taxable_service_fee_total, 0) <> 0
    or coalesce(service_fee_tax_amount, 0) <> 0
  );

-- Restore the three templates removed while diagnosing the public-pricing leak.
insert into public.service_fees (name, service_type, amount, taxable, active, description)
select values_to_restore.name,
       values_to_restore.service_type,
       values_to_restore.amount,
       true,
       true,
       values_to_restore.description
from (values
  ('Vehicle Reactivation Fee', 'reactivation_fee', 50.00::numeric, 'Vehicle reactivation fee due after speeding and/or non-payment.'),
  ('Over 90 MPH 3 Xs Violation Fee', 'speeding_violation_fee', 25.00::numeric, 'Each time over 90 MPH; after the fourth event disable the vehicle and apply the mandatory reactivation fee.'),
  ('Over 100 MPH Violation', 'policy_speed_violation_fee', 50.00::numeric, 'Apply after the first over-100-MPH violation.')
) as values_to_restore(name, service_type, amount, description)
where not exists (
  select 1 from public.service_fees existing
  where lower(existing.name) = lower(values_to_restore.name)
);

create or replace function public.get_booking_quote(
  p_vehicle_id uuid,
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text default '9:00 AM',
  p_return_time text default '9:00 AM'
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_policy public.booking_policy_settings%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_under_25_settings public.under_25_pricing_settings%rowtype;
  v_pickup_at timestamptz;
  v_return_at timestamptz;
  v_earliest_pickup timestamptz;
  v_earliest_return timestamptz;
  v_actual_minutes integer := 0;
  v_billable_days integer := 0;
  v_valid boolean := true;
  v_error text := null;
  v_base_rental_total numeric := 0;
  v_tax_amount numeric := 0;
  v_security_deposit numeric := 0;
  v_total_due_today numeric := 0;
  v_under_25_rental_total numeric := 0;
  v_under_25_tax_amount numeric := 0;
  v_under_25_security_deposit numeric := 0;
  v_under_25_total_due_today numeric := 0;
begin
  select * into v_policy from public.booking_policy_settings where id = true;
  if not found then
    v_policy.minimum_rental_days := 1;
    v_policy.advance_notice_minutes := 0;
  end if;

  v_earliest_pickup := now() + make_interval(mins => v_policy.advance_notice_minutes);

  if p_pickup_date is null or p_return_date is null then
    v_valid := false;
    v_error := 'Choose pickup and return dates.';
  else
    begin
      v_pickup_at := public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time) at time zone 'America/New_York';
      v_return_at := public.rentmect_rental_timestamp(p_return_date, p_return_time) at time zone 'America/New_York';
      v_earliest_return := v_pickup_at + make_interval(hours => v_policy.minimum_rental_days * 24);
      v_actual_minutes := greatest(0, floor(extract(epoch from (v_return_at - v_pickup_at)) / 60.0)::integer);
      if v_return_at < v_earliest_return then
        v_valid := false;
        v_error := format(
          'Rentals require at least %s hours. The earliest return is %s.',
          v_policy.minimum_rental_days * 24,
          to_char(v_earliest_return at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM')
        );
      elsif v_pickup_at < v_earliest_pickup then
        v_valid := false;
        v_error := format(
          'The earliest available pickup is %s.',
          to_char(v_earliest_pickup at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM')
        );
      else
        v_billable_days := public.rentmect_billable_days(
          p_pickup_date, p_pickup_time, p_return_date, p_return_time
        );
      end if;
    exception when others then
      v_valid := false;
      v_error := 'Choose valid pickup and return dates and times.';
    end;
  end if;

  if p_vehicle_id is not null then
    select * into v_vehicle
    from public.vehicles
    where id = p_vehicle_id
      and (coalesce(published, false) or public.is_admin());
    if not found then
      v_valid := false;
      v_error := 'Vehicle not found.';
    else
      select * into v_under_25_settings
      from public.under_25_pricing_settings
      where id = true;

      v_base_rental_total := round(coalesce(v_vehicle.daily_rate, 0) * v_billable_days, 2);
      v_tax_amount := round(v_base_rental_total * 0.0635, 2);
      v_security_deposit := round(coalesce(v_vehicle.security_deposit, 0), 2);
      v_total_due_today := round(
        v_base_rental_total + v_tax_amount + v_security_deposit,
        2
      );

      v_under_25_rental_total := round(public.rentmect_calculate_under25_rental(v_base_rental_total), 2);
      v_under_25_tax_amount := round(v_under_25_rental_total * 0.0635, 2);
      v_under_25_security_deposit := round(public.rentmect_calculate_under25_deposit(v_security_deposit), 2);
      v_under_25_total_due_today := round(
        v_under_25_rental_total + v_under_25_tax_amount + v_under_25_security_deposit,
        2
      );
    end if;
  end if;

  return jsonb_build_object(
    'valid', v_valid,
    'error', v_error,
    'vehicle_id', p_vehicle_id,
    'minimum_rental_days', v_policy.minimum_rental_days,
    'minimum_rental_hours', v_policy.minimum_rental_days * 24,
    'advance_notice_minutes', v_policy.advance_notice_minutes,
    'actual_duration_minutes', v_actual_minutes,
    'billable_days', v_billable_days,
    'earliest_pickup_at', case when v_earliest_pickup is null then null else to_char(v_earliest_pickup at time zone 'America/New_York', 'YYYY-MM-DD"T"HH24:MI:SS') end,
    'earliest_return_at', case when v_earliest_return is null then null else to_char(v_earliest_return at time zone 'America/New_York', 'YYYY-MM-DD"T"HH24:MI:SS') end,
    'daily_rate', round(coalesce(v_vehicle.daily_rate, 0), 2),
    'base_rental_total', v_base_rental_total,
    'service_fee_total', 0,
    'tax_amount', v_tax_amount,
    'security_deposit', v_security_deposit,
    'total_due_today', v_total_due_today,
    'pricing_age_tier', 'age_25_plus_estimate',
    'under_25_markup_percentage', round(coalesce(v_under_25_settings.rental_markup_percentage, 10), 2),
    'under_25_rental_total', v_under_25_rental_total,
    'under_25_tax_amount', v_under_25_tax_amount,
    'under_25_security_deposit', v_under_25_security_deposit,
    'under_25_total_due_today', v_under_25_total_due_today,
    'server_now', now()
  );
end;
$$;

revoke all on function public.get_booking_quote(uuid, date, date, text, text) from public;
grant execute on function public.get_booking_quote(uuid, date, date, text, text) to anon, authenticated;

comment on function public.get_booking_quote(uuid, date, date, text, text) is
  'Returns public rental, tax, and deposit totals. Internal admin fee templates are always excluded.';

commit;
