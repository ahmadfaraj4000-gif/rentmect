begin;

-- Return a complete, server-calculated public quote. Anonymous customers see
-- the standard (age 25+) amount and an exact age 21-24 comparison before they
-- create a checkout hold. The authenticated rental trigger remains the final
-- authority once the driver's verified date of birth is known.
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
  v_service_fee_total numeric := 0;
  v_taxable_service_fee_total numeric := 0;
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
      select
        coalesce(sum(amount), 0),
        coalesce(sum(amount) filter (where taxable), 0)
      into v_service_fee_total, v_taxable_service_fee_total
      from public.service_fees
      where active;

      select * into v_under_25_settings
      from public.under_25_pricing_settings
      where id = true;

      v_base_rental_total := round(coalesce(v_vehicle.daily_rate, 0) * v_billable_days, 2);
      v_service_fee_total := round(v_service_fee_total, 2);
      v_tax_amount := round((v_base_rental_total + v_taxable_service_fee_total) * 0.0635, 2);
      v_security_deposit := round(coalesce(v_vehicle.security_deposit, 0), 2);
      v_total_due_today := round(
        v_base_rental_total + v_service_fee_total + v_tax_amount + v_security_deposit,
        2
      );

      v_under_25_rental_total := round(public.rentmect_calculate_under25_rental(v_base_rental_total), 2);
      v_under_25_tax_amount := round((v_under_25_rental_total + v_taxable_service_fee_total) * 0.0635, 2);
      v_under_25_security_deposit := round(public.rentmect_calculate_under25_deposit(v_security_deposit), 2);
      v_under_25_total_due_today := round(
        v_under_25_rental_total + v_service_fee_total + v_under_25_tax_amount + v_under_25_security_deposit,
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
    'service_fee_total', v_service_fee_total,
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
  'Returns the standard complete amount due today plus an exact age 21-24 comparison; authenticated rental pricing is recalculated from the verified driver birth date.';

commit;
