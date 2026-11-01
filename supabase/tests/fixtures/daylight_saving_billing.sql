-- Minimal isolated schema; production booking/late-charge function bodies below.
create role anon; create role authenticated; create role service_role;
create table booking_policy_settings(id boolean primary key,minimum_rental_days integer,advance_notice_minutes integer);
insert into booking_policy_settings values(true,1,0);
create table vehicles(id uuid primary key,daily_rate numeric,security_deposit numeric,published boolean);
create table under_25_pricing_settings(id boolean,rental_markup_percentage numeric);
create table pending_bookings(id uuid primary key,status text,source text,pickup_date date,pickup_time text,return_date date,return_time text,minimum_rental_days_applied integer,advance_notice_minutes_applied integer);
create table rentals(id uuid primary key,user_id uuid,vehicle_id uuid,status text,pickup_date date,pickup_time text,return_date date,return_time text,minimum_rental_days_applied integer,advance_notice_minutes_applied integer,source_pending_booking_id uuid,actual_duration_minutes integer,billable_days integer,rental_total numeric,pre_discount_rental_total numeric,base_rental_total numeric);
create table rental_charge_items(id uuid default gen_random_uuid(),rental_id uuid,user_id uuid,name text,charge_type text,description text,amount numeric,taxable boolean,tax_amount numeric,total_amount numeric,included_in_initial_payment boolean,status text,created_by uuid,source_type text,source_reference text);
create unique index on rental_charge_items(source_type,source_reference) where source_type is not null and source_reference is not null;
create table rental_audit_events(id uuid default gen_random_uuid(),rental_id uuid,user_id uuid,actor_id uuid,event_type text,event_payload jsonb);
create function is_admin() returns boolean language sql as $$select false$$;
create function rentmect_time_to_time(t text) returns time language sql immutable as $$select t::time$$;
create function rentmect_calculate_under25_rental(n numeric) returns numeric language sql as $$select n*1.1$$;
create function rentmect_calculate_under25_deposit(n numeric) returns numeric language sql as $$select n$$;

CREATE OR REPLACE FUNCTION public.rentmect_rental_timestamp(p_date date, p_time text)
 RETURNS timestamp without time zone
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select p_date + public.rentmect_time_to_time(p_time);
$function$
;

CREATE OR REPLACE FUNCTION public.rentmect_billable_days(p_pickup_date date, p_pickup_time text, p_return_date date, p_return_time text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select greatest(
    1,
    ceil(
      extract(epoch from (
        (public.rentmect_rental_timestamp(p_return_date, p_return_time)
          at time zone 'America/New_York')
          - (public.rentmect_rental_timestamp(p_pickup_date, p_pickup_time)
            at time zone 'America/New_York')
      )) / 86400.0
    )::integer
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_booking_quote(p_vehicle_id uuid, p_pickup_date date, p_return_date date, p_pickup_time text DEFAULT '9:00 AM'::text, p_return_time text DEFAULT '9:00 AM'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_booking_policy_on_pending_booking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_policy public.booking_policy_settings%rowtype;
  v_pickup_at timestamptz;
  v_return_at timestamptz;
begin
  if lower(coalesce(new.status, 'pending')) <> 'pending' then
    return new;
  end if;
  if tg_op = 'UPDATE' and
     (new.pickup_date, new.pickup_time, new.return_date, new.return_time)
       is not distinct from
     (old.pickup_date, old.pickup_time, old.return_date, old.return_time) then
    return new;
  end if;

  select * into v_policy from public.booking_policy_settings where id = true;
  new.minimum_rental_days_applied := coalesce(v_policy.minimum_rental_days, 1);
  new.advance_notice_minutes_applied := coalesce(v_policy.advance_notice_minutes, 0);
  v_pickup_at := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time) at time zone 'America/New_York';
  v_return_at := public.rentmect_rental_timestamp(new.return_date, new.return_time) at time zone 'America/New_York';

  if v_return_at < v_pickup_at + make_interval(hours => new.minimum_rental_days_applied * 24) then
    raise exception 'Rentals require at least % hours. The earliest return is %.',
      new.minimum_rental_days_applied * 24,
      to_char((v_pickup_at + make_interval(hours => new.minimum_rental_days_applied * 24)) at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM');
  end if;
  if coalesce(lower(new.source), 'website') = 'website'
     and v_pickup_at < now() + make_interval(mins => new.advance_notice_minutes_applied) then
    raise exception 'The earliest available pickup is %.',
      to_char((now() + make_interval(mins => new.advance_notice_minutes_applied)) at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM');
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_booking_policy_on_rental()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_policy public.booking_policy_settings%rowtype;
  v_pending public.pending_bookings%rowtype;
  v_pickup_at timestamptz;
  v_return_at timestamptz;
begin
  if tg_op = 'UPDATE' and
     (new.pickup_date, new.pickup_time, new.return_date, new.return_time)
       is not distinct from
     (old.pickup_date, old.pickup_time, old.return_date, old.return_time) then
    return new;
  end if;
  if tg_op = 'INSERT' and lower(coalesce(new.status, '')) in ('completed', 'cancelled') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    select * into v_policy from public.booking_policy_settings where id = true;
    if new.source_pending_booking_id is not null then
      select * into v_pending
      from public.pending_bookings
      where id = new.source_pending_booking_id;
    end if;
    new.minimum_rental_days_applied := coalesce(
      v_pending.minimum_rental_days_applied,
      v_policy.minimum_rental_days,
      1
    );
    new.advance_notice_minutes_applied := coalesce(
      v_pending.advance_notice_minutes_applied,
      v_policy.advance_notice_minutes,
      0
    );
  end if;

  v_pickup_at := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time) at time zone 'America/New_York';
  v_return_at := public.rentmect_rental_timestamp(new.return_date, new.return_time) at time zone 'America/New_York';
  if v_return_at < v_pickup_at + make_interval(hours => coalesce(new.minimum_rental_days_applied, 1) * 24) then
    raise exception 'Rentals require at least % hours. The earliest return is %.',
      coalesce(new.minimum_rental_days_applied, 1) * 24,
      to_char((v_pickup_at + make_interval(hours => coalesce(new.minimum_rental_days_applied, 1) * 24)) at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM');
  end if;

  if tg_op = 'INSERT'
     and new.source_pending_booking_id is null
     and v_pickup_at < now() + make_interval(mins => coalesce(new.advance_notice_minutes_applied, 0)) then
    raise exception 'The earliest available pickup is %.',
      to_char((now() + make_interval(mins => coalesce(new.advance_notice_minutes_applied, 0))) at time zone 'America/New_York', 'Mon FMDD, YYYY at FMHH12:MI AM');
  end if;

  new.actual_duration_minutes := floor(extract(epoch from (v_return_at - v_pickup_at)) / 60.0)::integer;
  new.billable_days := public.rentmect_billable_days(
    new.pickup_date, new.pickup_time, new.return_date, new.return_time
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rentmect_stage_late_return_charges(p_as_of timestamp with time zone DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
to_char(
public.rentmect_rental_timestamp(
rental.return_date,
coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
),
'YYYYMMDDHH24MI'
) as return_window,
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
and p_as_of >= (
public.rentmect_rental_timestamp(
rental.return_date,
coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
) at time zone 'America/New_York'
) + interval '3 hours'
), inserted_late_fees as (
insert into public.rental_charge_items (
rental_id, user_id, name, charge_type, description, amount, taxable,
tax_amount, total_amount, included_in_initial_payment, status, created_by,
source_type, source_reference
)
select
late_rentals.rental_id,
late_rentals.user_id,
'Late return fee - grace expired',
'late_fee',
'Automatic $25 late-return assessment after the three-hour grace period. Payment requires administrator action.',
25,
true,
round(25 * 0.0635, 2),
round(25 + round(25 * 0.0635, 2), 2),
false,
'pending',
null,
'late_return',
late_rentals.rental_id::text || ':return:'
|| late_rentals.return_window || ':late-fee'
from late_rentals
where not exists (
select 1
from public.rental_charge_items existing
where existing.rental_id = late_rentals.rental_id
and existing.source_type = 'late_return'
and existing.source_reference = late_rentals.rental_id::text || ':late-fee'
and coalesce(existing.description, '') not like '%[AUTO-WAIVED:%'
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
late_rentals.return_window,
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
'Automatic late-return assessment after grace: additional rental day '
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
daily_periods.rental_id::text || ':return:'
|| daily_periods.return_window
|| ':period:' || daily_periods.period_number::text
from daily_periods
where daily_periods.daily_amount > 0
and not exists (
select 1
from public.rental_charge_items existing
where existing.rental_id = daily_periods.rental_id
and existing.source_type = 'late_return'
and existing.source_reference = daily_periods.rental_id::text
|| ':period:' || daily_periods.period_number::text
and coalesce(existing.description, '') not like '%[AUTO-WAIVED:%'
)
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
'payment_attempted', false,
'grace_period_minutes', 180
)
from inserted_charges
returning id
)
select count(*) into v_staged_count from audited_charges;

return v_staged_count;
end;
$function$;

create trigger policy before insert or update on pending_bookings for each row execute function enforce_booking_policy_on_pending_booking();
create trigger policy before insert or update on rentals for each row execute function enforce_booking_policy_on_rental();
