begin;

-- New reservations receive the increased mileage allowance. Existing signed
-- agreements and their snapshots remain immutable.
alter table public.rentals
  alter column mileage_policy
  set default '250 miles/day included; excess mileage $0.35/mile';

update public.rentals
set mileage_policy = '250 miles/day included; excess mileage $0.35/mile',
    updated_at = now()
where coalesce(agreement_signed, false) = false
  and lower(coalesce(status, '')) not in ('completed', 'cancelled')
  and mileage_policy = '200 miles/day included; excess mileage $0.35/mile';

-- Replace the legacy mileage fallback in every currently installed public
-- function without replaying old migrations or changing signed snapshots.
do $$
declare
  routine record;
begin
  for routine in
    select procedure.oid
    from pg_proc procedure
    join pg_namespace namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.prokind = 'f'
      and procedure.prosrc like '%200 miles/day included; excess mileage $0.35/mile%'
  loop
    execute replace(
      pg_get_functiondef(routine.oid),
      '200 miles/day included; excess mileage $0.35/mile',
      '250 miles/day included; excess mileage $0.35/mile'
    );
  end loop;
end
$$;

-- Split still-editable legacy combined charges into the daily charge that
-- keeps the existing period source reference. The separate $25 assessment is
-- staged below. Paid, waived, and open-checkout legacy charges are preserved
-- exactly so a customer is never assessed the same fee twice.
update public.rental_charge_items
set name = 'Late return - additional rental day',
    description = 'Automatic late-return assessment: one additional rental day at '
      || to_char(round(amount - 25, 2), 'FM$999,999,990.00')
      || '. Payment requires administrator action.',
    amount = round(amount - 25, 2),
    tax_amount = round((amount - 25) * 0.0635, 2),
    total_amount = round(
      round(amount - 25, 2) + round((amount - 25) * 0.0635, 2),
      2
    ),
    updated_at = now()
where source_type = 'late_return'
  and source_reference = rental_id::text || ':period:1'
  and name = 'Late return - day 1 plus $25 fee'
  and status in ('pending', 'failed')
  and amount > 25;

-- Stage two independent, idempotent assessments for administrator review:
-- $25 at 30 minutes, then one rental day strictly after two hours. Payment is
-- never attempted by this function.
create or replace function public.rentmect_stage_late_return_charges(
  p_as_of timestamptz default now()
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staged_count integer := 0;
begin
  with late_rentals as (
    select
      rental.id as rental_id,
      rental.user_id,
      public.rentmect_rental_timestamp(
        rental.return_date,
        coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
      ) at time zone 'America/New_York' as due_at,
      greatest(
        1,
        public.rentmect_billable_days(
          rental.pickup_date,
          coalesce(nullif(trim(rental.pickup_time), ''), '9:00 AM'),
          rental.return_date,
          coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
        )
      ) as original_days,
      greatest(
        coalesce(
          nullif(rental.rental_total, 0),
          nullif(rental.pre_discount_rental_total, 0),
          nullif(rental.base_rental_total, 0),
          0
        ),
        0
      ) as contracted_rental_total,
      greatest(coalesce(vehicle.daily_rate, 0), 0) as fallback_daily_amount
    from public.rentals rental
    left join public.vehicles vehicle on vehicle.id = rental.vehicle_id
    where lower(coalesce(rental.status, '')) in ('active', 'rented', 'overdue')
      and rental.pickup_date is not null
      and rental.return_date is not null
  ), inserted_late_fees as (
    insert into public.rental_charge_items (
      rental_id, user_id, name, charge_type, description, amount, taxable,
      tax_amount, total_amount, included_in_initial_payment, status, created_by,
      source_type, source_reference
    )
    select
      late_rentals.rental_id,
      late_rentals.user_id,
      'Late return fee - 30 minutes',
      'late_fee',
      'Automatic $25 late-return assessment at 30 minutes. Payment requires administrator action.',
      25,
      true,
      round(25 * 0.0635, 2),
      round(25 + round(25 * 0.0635, 2), 2),
      false,
      'pending',
      null,
      'late_return',
      late_rentals.rental_id::text || ':late-fee'
    from late_rentals
    where p_as_of >= late_rentals.due_at + interval '30 minutes'
      and not exists (
        select 1
        from public.rental_charge_items legacy_charge
        where legacy_charge.source_type = 'late_return'
          and legacy_charge.source_reference = late_rentals.rental_id::text || ':period:1'
          and (
            legacy_charge.name = 'Late return - day 1 plus $25 fee'
            or coalesce(legacy_charge.description, '') ilike '%plus the one-time $25 late-return fee%'
          )
      )
    on conflict (source_type, source_reference)
      where source_type is not null and source_reference is not null
      do nothing
    returning id, rental_id, user_id, name, amount, tax_amount, total_amount,
      source_reference
  ), daily_periods as (
    select
      late_rentals.rental_id,
      late_rentals.user_id,
      periods.period_number,
      round(
        case
          when late_rentals.contracted_rental_total > 0
            then late_rentals.contracted_rental_total / late_rentals.original_days
          else late_rentals.fallback_daily_amount
        end,
        2
      ) as daily_amount
    from late_rentals
    cross join lateral generate_series(
      1,
      greatest(
        1,
        ceil(extract(epoch from (p_as_of - late_rentals.due_at)) / 86400.0)::integer
      )
    ) as periods(period_number)
    where p_as_of > late_rentals.due_at + interval '2 hours'
  ), inserted_daily_charges as (
    insert into public.rental_charge_items (
      rental_id, user_id, name, charge_type, description, amount, taxable,
      tax_amount, total_amount, included_in_initial_payment, status, created_by,
      source_type, source_reference
    )
    select
      daily_periods.rental_id,
      daily_periods.user_id,
      case
        when daily_periods.period_number = 1
          then 'Late return - additional rental day'
        else 'Late return - additional day ' || daily_periods.period_number::text
      end,
      'late_fee',
      'Automatic late-return assessment: additional rental day '
        || daily_periods.period_number::text || ' at '
        || to_char(daily_periods.daily_amount, 'FM$999,999,990.00')
        || '. Payment requires administrator action.',
      daily_periods.daily_amount,
      true,
      round(daily_periods.daily_amount * 0.0635, 2),
      round(
        daily_periods.daily_amount
          + round(daily_periods.daily_amount * 0.0635, 2),
        2
      ),
      false,
      'pending',
      null,
      'late_return',
      daily_periods.rental_id::text
        || ':period:' || daily_periods.period_number::text
    from daily_periods
    where daily_periods.daily_amount > 0
    on conflict (source_type, source_reference)
      where source_type is not null and source_reference is not null
      do nothing
    returning id, rental_id, user_id, name, amount, tax_amount, total_amount,
      source_reference
  ), inserted_charges as (
    select * from inserted_late_fees
    union all
    select * from inserted_daily_charges
  ), audited_charges as (
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    )
    select
      inserted_charges.rental_id,
      inserted_charges.user_id,
      null,
      'late_return_charge_staged',
      jsonb_build_object(
        'charge_id', inserted_charges.id,
        'source_reference', inserted_charges.source_reference,
        'name', inserted_charges.name,
        'amount', inserted_charges.amount,
        'tax_amount', inserted_charges.tax_amount,
        'total_amount', inserted_charges.total_amount,
        'payment_attempted', false
      )
    from inserted_charges
    returning id
  )
  select count(*) into v_staged_count from audited_charges;

  return v_staged_count;
end;
$$;

revoke all on function public.rentmect_stage_late_return_charges(timestamptz)
  from public, anon, authenticated;
grant execute on function public.rentmect_stage_late_return_charges(timestamptz)
  to service_role;

comment on function public.rentmect_stage_late_return_charges(timestamptz) is
  'Stages an idempotent $25 fee at 30 minutes and an additional rental day strictly after two hours; later started 24-hour periods add another rental day. Payment remains admin-triggered.';

notify pgrst, 'reload schema';

commit;
