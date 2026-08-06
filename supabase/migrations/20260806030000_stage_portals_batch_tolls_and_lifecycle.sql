begin;

-- One compact request for the only data the initial admin dashboard renders.
create or replace function public.get_admin_dashboard_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_snapshot jsonb;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  with paid_rentals as (
    select rental.*
    from public.rentals rental
    where lower(coalesce(rental.status, '')) <> 'cancelled'
      and (
        lower(coalesce(rental.payment_status, '')) in ('paid', 'partially_paid', 'partial')
        or lower(coalesce(rental.deposit_status, '')) in ('held', 'adjustment_refund_due', 'release_pending')
        or rental.paid_at is not null
        or lower(coalesce(rental.status, '')) in ('documents_needed', 'document_review', 'ready_for_pickup', 'approved', 'active', 'overdue', 'return_initiated')
      )
  ), return_rows as (
    select
      to_jsonb(rental) || jsonb_build_object(
        'vehicles', to_jsonb(vehicle),
        'profiles', to_jsonb(profile)
      ) as rental,
      public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
        at time zone 'America/New_York' as due_at,
      lower(coalesce(rental.status, '')) = 'overdue'
        or (public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
          at time zone 'America/New_York') < v_now as overdue
    from paid_rentals rental
    left join public.vehicles vehicle on vehicle.id = rental.vehicle_id
    left join public.profiles profile on profile.id = rental.user_id
    where lower(coalesce(rental.status, '')) not in ('completed', 'cancelled')
      and rental.return_date is not null
  ), maintenance as (
    select count(distinct vehicle.id)::integer as due_count
    from public.vehicles vehicle
    left join public.vehicle_maintenance_schedules schedule on schedule.vehicle_id = vehicle.id
    where coalesce(vehicle.maintenance_lock_active, false)
       or (schedule.active and schedule.next_due_at is not null and schedule.next_due_at <= current_date)
       or (schedule.active and schedule.next_due_mileage is not null and coalesce(vehicle.current_mileage, 0) >= schedule.next_due_mileage)
  )
  select jsonb_build_object(
    'cars_out', (select count(*) from paid_rentals where lower(coalesce(status, '')) in ('ready_for_pickup', 'approved', 'active', 'overdue', 'return_initiated')),
    'overdue_count', (select count(*) from return_rows where overdue),
    'maintenance_due', coalesce((select due_count from maintenance), 0),
    'month_revenue', coalesce((select sum(coalesce(rental_total, 0) + coalesce(tax_amount, 0)) from paid_rentals where payment_status = 'paid' and date_trunc('month', coalesce(paid_at, created_at)) = date_trunc('month', v_now)), 0),
    'active_deposits', coalesce((select sum(coalesce(deposit_held_amount, 0)) from paid_rentals where lower(coalesce(deposit_status, '')) in ('held', 'adjustment_refund_due', 'release_pending')), 0),
    'overdue_rentals', coalesce((select jsonb_agg(rental order by due_at) from return_rows where overdue), '[]'::jsonb),
    'due_soon_rentals', coalesce((select jsonb_agg(rental order by due_at) from return_rows where not overdue and due_at <= v_now + interval '24 hours'), '[]'::jsonb),
    'emergency_exceptions', coalesce((
      select jsonb_agg(
        to_jsonb(exception) || jsonb_build_object(
          'rentals', to_jsonb(rental) || jsonb_build_object('vehicles', to_jsonb(vehicle), 'profiles', to_jsonb(profile))
        ) order by exception.expires_at
      )
      from public.rental_emergency_exceptions exception
      left join public.rentals rental on rental.id = exception.rental_id
      left join public.vehicles vehicle on vehicle.id = rental.vehicle_id
      left join public.profiles profile on profile.id = rental.user_id
      where exception.status = 'active'
    ), '[]'::jsonb),
    'generated_at', v_now
  ) into v_snapshot;

  return v_snapshot;
end;
$$;

revoke all on function public.get_admin_dashboard_snapshot() from public, anon;
grant execute on function public.get_admin_dashboard_snapshot() to authenticated;

-- Match a polling page in one database operation. This replaces one RPC and
-- transaction per TollSpot row while retaining idempotent charge creation.
create or replace function public.service_match_tollspot_transactions(
  p_transaction_ids uuid[]
) returns setof public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  select coalesce(array_agg(distinct value), '{}'::uuid[])
  into v_ids
  from unnest(coalesce(p_transaction_ids, '{}'::uuid[])) as input(value)
  where value is not null;

  if cardinality(v_ids) > 1000 then
    raise exception 'A TollSpot match batch cannot exceed 1000 transactions.';
  end if;
  if cardinality(v_ids) = 0 then return; end if;

  perform 1
  from public.tollspot_transactions transaction
  where transaction.id = any(v_ids)
  order by transaction.id
  for update;

  with eligible as (
    select transaction.*
    from public.tollspot_transactions transaction
    where transaction.id = any(v_ids)
      and transaction.status not in ('charge_created', 'paid', 'ignored')
  ), resolved as (
    select
      transaction.id,
      vehicle_match.vehicle_id,
      vehicle_match.match_method,
      coalesce(rental_match.candidate_count, 0)::integer as candidate_count,
      rental_match.rental_id
    from eligible transaction
    left join lateral (
      select candidate.vehicle_id, candidate.match_method
      from (
        select mapping.vehicle_id, 'provider_vehicle_id'::text as match_method, 1 as priority
        from public.tollspot_vehicle_mappings mapping
        where mapping.active
          and mapping.tollspot_vehicle_id = transaction.tollspot_vehicle_id
        union all
        select assignment.vehicle_id, 'plate_assignment'::text, 2
        from public.tollspot_plate_assignments assignment
        where upper(assignment.plate_number) = upper(coalesce(transaction.license_plate, ''))
          and (nullif(transaction.license_plate_state, '') is null or upper(coalesce(assignment.plate_state, '')) = upper(transaction.license_plate_state))
          and (nullif(transaction.license_plate_country, '') is null or upper(coalesce(assignment.plate_country, '')) = upper(transaction.license_plate_country))
          and transaction.occurred_at >= assignment.assigned_at
          and (assignment.removed_at is null or transaction.occurred_at < assignment.removed_at)
      ) candidate
      order by candidate.priority
      limit 1
    ) vehicle_match on true
    left join lateral (
      select count(*) as candidate_count, min(rental.id::text)::uuid as rental_id
      from public.rentals rental
      where rental.vehicle_id = vehicle_match.vehicle_id
        and lower(coalesce(rental.status, '')) <> 'cancelled'
        and rental.pickup_date is not null
        and rental.return_date is not null
        and transaction.occurred_at >= (public.rentmect_rental_timestamp(rental.pickup_date, rental.pickup_time) at time zone 'America/New_York')
        and transaction.occurred_at <= (public.rentmect_rental_timestamp(rental.return_date, rental.return_time) at time zone 'America/New_York')
    ) rental_match on vehicle_match.vehicle_id is not null
  ), matched as (
    update public.tollspot_transactions transaction
    set
      vehicle_id = resolved.vehicle_id,
      rental_id = case when resolved.candidate_count = 1 then resolved.rental_id else null end,
      status = case when resolved.vehicle_id is not null and resolved.candidate_count = 1 and coalesce(transaction.transaction_type, 'TOLLS') = 'TOLLS' then 'matched' else 'needs_review' end,
      match_method = resolved.match_method,
      match_candidate_count = resolved.candidate_count,
      review_reason = case
        when resolved.vehicle_id is null then 'No local vehicle mapping matched the provider charge.'
        when coalesce(transaction.transaction_type, 'TOLLS') <> 'TOLLS' then 'Parking and violation transactions require explicit review.'
        when resolved.candidate_count = 0 then 'No rental interval contains the transaction occurrence time.'
        when resolved.candidate_count > 1 then 'More than one rental interval contains the transaction occurrence time.'
        else null
      end,
      updated_at = now()
    from resolved
    where transaction.id = resolved.id
    returning transaction.*
  ), created_charges as (
    insert into public.rental_charge_items (
      rental_id, user_id, name, charge_type, description, amount, taxable,
      tax_amount, total_amount, included_in_initial_payment, status,
      created_by, source_type, source_reference
    )
    select
      rental.id,
      rental.user_id,
      coalesce(nullif(trim(transaction.exit_location), ''), nullif(trim(transaction.road_or_plaza), ''), 'Toll charge'),
      'toll',
      concat_ws(' • ', nullif(trim(transaction.agency), ''), 'TollSpot transaction ' || transaction.tollspot_transaction_id),
      round(transaction.total_amount, 2), false, 0, round(transaction.total_amount, 2),
      false, 'pending', null, 'tollspot', transaction.tollspot_transaction_id
    from matched transaction
    join public.rentals rental on rental.id = transaction.rental_id
    where transaction.status = 'matched'
      and lower(coalesce(rental.status, '')) <> 'cancelled'
      and coalesce((select tollspot_auto_create_charges from public.billing_automation_settings where id = true), true)
    on conflict (source_type, source_reference)
      where source_type is not null and source_reference is not null
    do update set updated_at = now()
    returning id, rental_id, user_id, source_reference, total_amount
  ), charged_transactions as (
    update public.tollspot_transactions transaction
    set status = 'charge_created', rental_charge_item_id = charge.id,
        reviewed_by = null, reviewed_at = now(), review_reason = null, updated_at = now()
    from created_charges charge
    where transaction.tollspot_transaction_id = charge.source_reference
      and transaction.id = any(v_ids)
    returning transaction.*, charge.user_id as charge_user_id, charge.total_amount as charge_total_amount
  )
  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  select
    transaction.rental_id,
    transaction.charge_user_id,
    null,
    'tollspot_charge_automatically_added',
    jsonb_build_object(
      'charge_id', transaction.rental_charge_item_id,
      'tollspot_transaction_id', transaction.tollspot_transaction_id,
      'vehicle_id', transaction.vehicle_id,
      'amount', transaction.charge_total_amount
    )
  from charged_transactions transaction;

  return query
  select transaction.*
  from public.tollspot_transactions transaction
  where transaction.id = any(v_ids)
  order by transaction.occurred_at, transaction.id;
end;
$$;

revoke all on function public.service_match_tollspot_transactions(uuid[]) from public, anon, authenticated;
grant execute on function public.service_match_tollspot_transactions(uuid[]) to service_role;

-- The lifecycle functions already queue notifications through row-change
-- triggers. Cron remains only as the recovery clock for time-based transitions.
create or replace function public.run_rental_lifecycle_recovery()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired integer := 0;
  v_overdue integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;
  v_expired := coalesce(public.expire_stale_customer_checkout_holds(), 0);
  v_overdue := coalesce(public.reconcile_overdue_rentals(), 0);
  return jsonb_build_object('expired_checkout_records', v_expired, 'overdue_rentals', v_overdue, 'ran_at', now());
end;
$$;

revoke all on function public.run_rental_lifecycle_recovery() from public, anon, authenticated;
grant execute on function public.run_rental_lifecycle_recovery() to service_role;

create extension if not exists pg_cron;

select cron.unschedule(jobid)
from cron.job
where jobname in ('rentmect-expire-checkout-holds', 'rentmect-reconcile-overdue-rentals', 'rentmect-rental-lifecycle-recovery');

select cron.schedule(
  'rentmect-rental-lifecycle-recovery',
  '* * * * *',
  $$select public.run_rental_lifecycle_recovery();$$
);

notify pgrst, 'reload schema';

commit;
