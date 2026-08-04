begin;

-- Keep elapsed-day calculation available in every deployment source. Exactly
-- 24 hours is one day; any positive amount over 24 hours starts day two.
create or replace function public.rentmect_billable_days(
  p_pickup_date date,
  p_pickup_time text,
  p_return_date date,
  p_return_time text
) returns integer
language sql
immutable
security definer
set search_path = public
as $$
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
$$;

create or replace function public.rentmect_requires_physical_return_lock(
  p_status text,
  p_return_date date,
  p_return_time text
) returns boolean
language sql
stable
set search_path = public
as $$
  select case
    when lower(coalesce(p_status, '')) in ('overdue', 'return_initiated')
      then true
    when lower(coalesce(p_status, '')) in ('active', 'rented')
      and p_return_date is not null
      and now() >= (
        public.rentmect_rental_timestamp(p_return_date, p_return_time)
          at time zone 'America/New_York'
      ) + interval '3 hours'
      then true
    else false
  end;
$$;

-- Stage late-return charges for administrator review. Payment is never
-- attempted here: the existing Charge customer action remains the only path
-- that can charge a saved card.
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
      greatest(
        1,
        ceil(
          extract(epoch from (
            p_as_of - (
              public.rentmect_rental_timestamp(
                rental.return_date,
                coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
              ) at time zone 'America/New_York'
            )
          )) / 86400.0
        )::integer
      ) as late_days,
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
    where lower(coalesce(rental.status, '')) = 'overdue'
      and rental.pickup_date is not null
      and rental.return_date is not null
      and p_as_of >= (
        public.rentmect_rental_timestamp(
          rental.return_date,
          coalesce(nullif(trim(rental.return_time), ''), '9:00 AM')
        ) at time zone 'America/New_York'
      ) + interval '3 hours'
  ), charge_periods as (
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
    cross join lateral generate_series(1, late_rentals.late_days)
      as periods(period_number)
  ), inserted_charges as (
    insert into public.rental_charge_items (
      rental_id,
      user_id,
      name,
      charge_type,
      description,
      amount,
      taxable,
      tax_amount,
      total_amount,
      included_in_initial_payment,
      status,
      created_by,
      source_type,
      source_reference
    )
    select
      charge_periods.rental_id,
      charge_periods.user_id,
      case
        when charge_periods.period_number = 1
          then 'Late return - day 1 plus $25 fee'
        else 'Late return - day ' || charge_periods.period_number::text
      end,
      'late_fee',
      case
        when charge_periods.period_number = 1 then
          'Automatic late-return assessment: one additional rental day at '
            || to_char(charge_periods.daily_amount, 'FM$999,999,990.00')
            || ' plus the one-time $25 late-return fee. Payment requires administrator action.'
        else
          'Automatic late-return assessment: additional rental day '
            || charge_periods.period_number::text || ' at '
            || to_char(charge_periods.daily_amount, 'FM$999,999,990.00')
            || '. Payment requires administrator action.'
      end,
      round(
        charge_periods.daily_amount
          + case when charge_periods.period_number = 1 then 25 else 0 end,
        2
      ),
      true,
      round(
        (
          charge_periods.daily_amount
            + case when charge_periods.period_number = 1 then 25 else 0 end
        ) * 0.0635,
        2
      ),
      round(
        round(
          charge_periods.daily_amount
            + case when charge_periods.period_number = 1 then 25 else 0 end
        , 2)
        + round(
          (
            charge_periods.daily_amount
              + case when charge_periods.period_number = 1 then 25 else 0 end
          ) * 0.0635,
          2
        ),
        2
      ),
      false,
      'pending',
      null,
      'late_return',
      charge_periods.rental_id::text
        || ':period:' || charge_periods.period_number::text
    from charge_periods
    where charge_periods.daily_amount > 0
       or charge_periods.period_number = 1
    on conflict (source_type, source_reference)
      where source_type is not null and source_reference is not null
      do nothing
    returning id, rental_id, user_id, name, amount, tax_amount, total_amount,
      source_reference
  ), audited_charges as (
    insert into public.rental_audit_events (
      rental_id,
      user_id,
      actor_id,
      event_type,
      event_payload
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
  'Creates one idempotent pending charge for every started 24-hour late-return period. The first period also includes the one-time $25 late fee; payment remains admin-triggered.';

-- Automated late-return assessments are deliberately held for administrator
-- review. Other additional charges retain their existing automatic email.
create or replace function public.queue_additional_charge_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template public.email_templates%rowtype;
  v_profile public.profiles%rowtype;
begin
  if new.included_in_initial_payment
     or lower(coalesce(new.source_type, '')) = 'late_return' then
    return new;
  end if;

  select * into v_template
  from public.email_templates
  where template_key = 'additional_charge_due' and enabled
  limit 1;
  if not found then return new; end if;

  select * into v_profile from public.profiles where id = new.user_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;

  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'additional_charge_due:' || new.id::text,
    'additional_charge_due',
    v_template.id,
    new.rental_id,
    new.user_id,
    lower(trim(v_profile.email)),
    v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'charge_name', new.name,
      'charge_description', coalesce(new.description, 'Please contact Rent Me CT with any questions.'),
      'charge_total', to_char(new.total_amount, 'FM$999,999,990.00'),
      'manage_booking_url', 'https://login.rentmect.com/?billing=1'
    )
  ) on conflict (event_key) do nothing;

  return new;
end;
$$;

-- Keep the overdue event valid even when this migration is deployed from a
-- source branch that predates the original inventory-lock migration.
do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_constraint
    where conrelid = 'public.admin_notification_events'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%event_type%'
  loop
    execute format(
      'alter table public.admin_notification_events drop constraint %I',
      constraint_name
    );
  end loop;

  alter table public.admin_notification_events
    add constraint admin_notification_events_event_type_check
    check (
      event_type in (
        'new_booking',
        'document_pending_review',
        'return_due_today',
        'maintenance_due',
        'maintenance_due_soon',
        'maintenance_override',
        'extension_requested',
        'extension_approved',
        'emergency_exception_created',
        'rental_payment_received',
        'extension_payment_received',
        'rental_overdue',
        'vehicle_price_changed',
        'rental_return_initiated',
        'customer_message_received',
        'vehicle_report_submitted',
        'toll_needs_review',
        'toll_sync_failed',
        'customer_charge_failed',
        'refund_failed',
        'deposit_release_failed',
        'rental_cancelled',
        'rental_ready_for_pickup',
        'identity_verification_failed',
        'extension_payment_failed',
        'rental_payment_failed',
        'chargeback_created'
      )
    );
end
$$;

-- Preserve the existing overdue inventory workflow while adding charge
-- staging before the administrator notification is queued.
create or replace function public.reconcile_overdue_rentals()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  updated_count integer := 0;
begin
  with updated as (
    update public.rentals rental
    set status = 'overdue', updated_at = now()
    where lower(coalesce(rental.status, '')) in ('active', 'rented')
      and public.rentmect_requires_physical_return_lock(
        rental.status,
        rental.return_date,
        rental.return_time
      )
    returning rental.id
  )
  select count(*) into updated_count from updated;

  update public.vehicles vehicle
  set status = 'rented'
  where exists (
    select 1
    from public.rentals rental
    where rental.vehicle_id = vehicle.id
      and lower(coalesce(rental.status, '')) = 'overdue'
  )
    and lower(coalesce(vehicle.status, 'available')) not in (
      'maintenance', 'unavailable', 'inactive'
    )
    and vehicle.status is distinct from 'rented';

  perform public.rentmect_stage_late_return_charges(now());

  insert into public.admin_notification_events (
    event_type,
    source_id,
    rental_id,
    dedupe_key,
    metadata
  )
  select
    'rental_overdue',
    rental.id,
    rental.id,
    'rental_overdue:' || rental.id::text,
    jsonb_build_object(
      'scheduled_return_date', rental.return_date,
      'scheduled_return_time', rental.return_time,
      'vehicle_id', rental.vehicle_id,
      'late_charge_staged', true
    )
  from public.rentals rental
  where lower(coalesce(rental.status, '')) = 'overdue'
  on conflict (dedupe_key) do nothing;

  return updated_count;
end;
$$;

revoke all on function public.reconcile_overdue_rentals()
  from public, anon, authenticated;
grant execute on function public.reconcile_overdue_rentals()
  to service_role;

notify pgrst, 'reload schema';

commit;
