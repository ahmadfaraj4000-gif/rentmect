begin;

-- Keep one durable possession timeline per rental. Toll attribution must follow
-- the vehicle the customer actually had, including extensions and swaps.
create or replace function public.sync_rental_vehicle_assignment_duration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pickup_at timestamptz;
  v_return_at timestamptz;
  v_effective_at timestamptz;
  v_latest public.rental_vehicle_assignments%rowtype;
  v_assignment_count integer := 0;
  v_on_road boolean := false;
begin
  if new.vehicle_id is null or new.pickup_date is null or new.return_date is null then
    return new;
  end if;

  v_pickup_at := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time)
    at time zone 'America/New_York';
  v_return_at := coalesce(
    new.inspection_completed_at,
    public.rentmect_rental_timestamp(new.return_date, new.return_time)
      at time zone 'America/New_York'
  );
  v_on_road := lower(coalesce(new.status, '')) in (
    'active', 'rented', 'overdue', 'return_initiated'
  );

  select assignment.*
  into v_latest
  from public.rental_vehicle_assignments assignment
  where assignment.rental_id = new.id
  order by assignment.assigned_from desc, assignment.created_at desc
  limit 1;

  if not found then
    insert into public.rental_vehicle_assignments (
      rental_id, vehicle_id, assigned_from, assigned_until, source
    ) values (
      new.id, new.vehicle_id, v_pickup_at,
      greatest(v_pickup_at, v_return_at), 'initial'
    );
    return new;
  end if;

  select count(*) into v_assignment_count
  from public.rental_vehicle_assignments assignment
  where assignment.rental_id = new.id;

  if v_latest.vehicle_id = new.vehicle_id then
    update public.rental_vehicle_assignments
    set
      assigned_from = case
        when v_assignment_count = 1 and not v_on_road
          then least(v_pickup_at, greatest(v_pickup_at, v_return_at))
        else assigned_from
      end,
      assigned_until = greatest(
        case
          when v_assignment_count = 1 and not v_on_road then v_pickup_at
          else assigned_from
        end,
        v_return_at
      )
    where id = v_latest.id;
    return new;
  end if;

  -- This is a safety net for direct vehicle updates. The guarded amendment
  -- function normally writes the swap first, so it will not duplicate it here.
  v_effective_at := case
    when v_on_road and now() > v_pickup_at then now()
    else v_pickup_at
  end;

  update public.rental_vehicle_assignments
  set assigned_until = greatest(assigned_from, v_effective_at)
  where id = v_latest.id;

  insert into public.rental_vehicle_assignments (
    rental_id, vehicle_id, assigned_from, assigned_until, source
  ) values (
    new.id, new.vehicle_id, v_effective_at,
    greatest(v_effective_at, v_return_at),
    case when v_on_road then 'active_swap' else 'admin_edit' end
  );

  return new;
end;
$$;

drop trigger if exists rentals_sync_vehicle_assignment_duration on public.rentals;
create trigger rentals_sync_vehicle_assignment_duration
after insert or update of
  vehicle_id, pickup_date, pickup_time, return_date, return_time,
  status, inspection_completed_at
on public.rentals
for each row execute function public.sync_rental_vehicle_assignment_duration();

-- Seed missing ledgers and repair the end of the current assignment. Historical
-- swap rows are preserved.
insert into public.rental_vehicle_assignments (
  rental_id, vehicle_id, assigned_from, assigned_until, source
)
select
  rental.id,
  rental.vehicle_id,
  public.rentmect_rental_timestamp(rental.pickup_date, rental.pickup_time)
    at time zone 'America/New_York',
  greatest(
    public.rentmect_rental_timestamp(rental.pickup_date, rental.pickup_time)
      at time zone 'America/New_York',
    coalesce(
      rental.inspection_completed_at,
      public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
        at time zone 'America/New_York'
    )
  ),
  'initial'
from public.rentals rental
where rental.vehicle_id is not null
  and rental.pickup_date is not null
  and rental.return_date is not null
  and not exists (
    select 1
    from public.rental_vehicle_assignments assignment
    where assignment.rental_id = rental.id
  );

with latest_current_assignment as (
  select distinct on (assignment.rental_id)
    assignment.id,
    assignment.assigned_from,
    rental.inspection_completed_at,
    public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
      at time zone 'America/New_York' as scheduled_return_at
  from public.rental_vehicle_assignments assignment
  join public.rentals rental
    on rental.id = assignment.rental_id
   and rental.vehicle_id = assignment.vehicle_id
  where rental.return_date is not null
  order by assignment.rental_id, assignment.assigned_from desc, assignment.created_at desc
)
update public.rental_vehicle_assignments assignment
set assigned_until = greatest(
  assignment.assigned_from,
  coalesce(latest.inspection_completed_at, latest.scheduled_return_at)
)
from latest_current_assignment latest
where assignment.id = latest.id
  and assignment.assigned_until is distinct from greatest(
    assignment.assigned_from,
    coalesce(latest.inspection_completed_at, latest.scheduled_return_at)
  );

create or replace function public.rental_vehicle_possession_contains(
  p_rental_id uuid,
  p_vehicle_id uuid,
  p_occurred_at timestamptz
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select
      lower(coalesce(rental.status, '')) <> 'cancelled'
      and (
        exists (
          select 1
          from public.rental_vehicle_assignments assignment
          where assignment.rental_id = rental.id
            and assignment.vehicle_id = p_vehicle_id
            and p_occurred_at >= assignment.assigned_from
            and p_occurred_at < coalesce(
              case
                when assignment.id = (
                  select latest.id
                  from public.rental_vehicle_assignments latest
                  where latest.rental_id = rental.id
                  order by latest.assigned_from desc, latest.created_at desc
                  limit 1
                ) and assignment.vehicle_id = rental.vehicle_id then
                  case
                    when rental.inspection_completed_at is not null
                      then rental.inspection_completed_at
                    when lower(coalesce(rental.status, '')) in (
                      'active', 'rented', 'overdue', 'return_initiated'
                    ) then 'infinity'::timestamptz
                    else assignment.assigned_until
                  end
                else assignment.assigned_until
              end,
              'infinity'::timestamptz
            )
        )
        or (
          not exists (
            select 1
            from public.rental_vehicle_assignments assignment
            where assignment.rental_id = rental.id
          )
          and rental.vehicle_id = p_vehicle_id
          and rental.pickup_date is not null
          and rental.return_date is not null
          and p_occurred_at >= (
            public.rentmect_rental_timestamp(rental.pickup_date, rental.pickup_time)
              at time zone 'America/New_York'
          )
          and p_occurred_at < case
            when rental.inspection_completed_at is not null
              then rental.inspection_completed_at
            when lower(coalesce(rental.status, '')) in (
              'active', 'rented', 'overdue', 'return_initiated'
            ) then 'infinity'::timestamptz
            else public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
              at time zone 'America/New_York'
          end
        )
      )
    from public.rentals rental
    where rental.id = p_rental_id
  ), false);
$$;

revoke all on function public.rental_vehicle_possession_contains(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function public.rental_vehicle_possession_contains(uuid, uuid, timestamptz)
  to service_role;

-- Match provider records only through an explicit provider vehicle mapping or
-- a time-valid local plate assignment. Rental matching follows possession
-- history and remains open until the physical return inspection for cars out.
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
        join public.vehicles vehicle on vehicle.id = mapping.vehicle_id
        where mapping.active
          and vehicle.tollspot_enabled
          and mapping.tollspot_vehicle_id = transaction.tollspot_vehicle_id
        union all
        select assignment.vehicle_id, 'plate_assignment'::text, 2
        from public.tollspot_plate_assignments assignment
        join public.vehicles vehicle on vehicle.id = assignment.vehicle_id
        where vehicle.tollspot_enabled
          and upper(assignment.plate_number) = upper(coalesce(transaction.license_plate, ''))
          and (nullif(transaction.license_plate_state, '') is null
            or upper(coalesce(assignment.plate_state, '')) = upper(transaction.license_plate_state))
          and (nullif(transaction.license_plate_country, '') is null
            or upper(coalesce(assignment.plate_country, '')) = upper(transaction.license_plate_country))
          and transaction.occurred_at >= assignment.assigned_at
          and (assignment.removed_at is null or transaction.occurred_at < assignment.removed_at)
      ) candidate
      order by candidate.priority
      limit 1
    ) vehicle_match on true
    left join lateral (
      select count(*) as candidate_count, min(candidate.id::text)::uuid as rental_id
      from (
        select rental.id
        from public.rentals rental
        where lower(coalesce(rental.status, '')) <> 'cancelled'
          and (
            rental.vehicle_id = vehicle_match.vehicle_id
            or exists (
              select 1
              from public.rental_vehicle_assignments assignment
              where assignment.rental_id = rental.id
                and assignment.vehicle_id = vehicle_match.vehicle_id
            )
          )
          and public.rental_vehicle_possession_contains(
            rental.id, vehicle_match.vehicle_id, transaction.occurred_at
          )
      ) candidate
    ) rental_match on vehicle_match.vehicle_id is not null
  ), matched as (
    update public.tollspot_transactions transaction
    set
      vehicle_id = resolved.vehicle_id,
      rental_id = case when resolved.candidate_count = 1 then resolved.rental_id else null end,
      status = case
        when resolved.vehicle_id is not null
          and resolved.candidate_count = 1
          and upper(coalesce(transaction.transaction_type, 'TOLLS')) = 'TOLLS'
          then 'matched'
        else 'needs_review'
      end,
      match_method = resolved.match_method,
      match_candidate_count = resolved.candidate_count,
      review_reason = case
        when resolved.vehicle_id is null
          then 'No Rent Me CT vehicle mapping matched the provider transaction.'
        when upper(coalesce(transaction.transaction_type, 'TOLLS')) <> 'TOLLS'
          then 'The provider record is not a toll transaction.'
        when resolved.candidate_count = 0
          then 'No Rent Me CT rental possession interval contains the toll time.'
        when resolved.candidate_count > 1
          then 'More than one Rent Me CT rental possession interval contains the toll time.'
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
      coalesce(nullif(trim(transaction.exit_location), ''),
        nullif(trim(transaction.road_or_plaza), ''), 'Toll charge'),
      'toll',
      concat_ws(' • ', nullif(trim(transaction.agency), ''),
        'TollSpot transaction ' || transaction.tollspot_transaction_id),
      round(transaction.total_amount, 2), false, 0, round(transaction.total_amount, 2),
      false, 'pending', null, 'tollspot', transaction.tollspot_transaction_id
    from matched transaction
    join public.rentals rental on rental.id = transaction.rental_id
    where transaction.status = 'matched'
      and rental.user_id is not null
      and lower(coalesce(rental.status, '')) <> 'cancelled'
      and coalesce((
        select tollspot_auto_create_charges
        from public.billing_automation_settings where id = true
      ), true)
    on conflict (source_type, source_reference)
      where source_type is not null and source_reference is not null
    do update set updated_at = now()
    returning id, rental_id, user_id, source_reference, total_amount, status
  ), charged_transactions as (
    update public.tollspot_transactions transaction
    set
      status = case
        when lower(coalesce(charge.status, '')) = 'paid' then 'paid'
        when lower(coalesce(charge.status, '')) = 'waived' then 'ignored'
        else 'charge_created'
      end,
      rental_charge_item_id = charge.id,
      reviewed_by = null,
      reviewed_at = now(),
      review_reason = null,
      updated_at = now()
    from created_charges charge
    where transaction.tollspot_transaction_id = charge.source_reference
      and transaction.id = any(v_ids)
    returning transaction.*, charge.user_id as charge_user_id,
      charge.total_amount as charge_total_amount
  )
  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  )
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

revoke all on function public.service_match_tollspot_transactions(uuid[])
  from public, anon, authenticated;
grant execute on function public.service_match_tollspot_transactions(uuid[])
  to service_role;

create or replace function public.admin_match_tollspot_transaction(
  p_transaction_id uuid,
  p_rental_id uuid
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  select * into v_transaction
  from public.tollspot_transactions
  where id = p_transaction_id
  for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then
    raise exception 'This TollSpot transaction can no longer be rematched.';
  end if;
  if v_transaction.vehicle_id is null then
    raise exception 'The provider transaction is not connected to a Rent Me CT vehicle.';
  end if;
  if upper(coalesce(v_transaction.transaction_type, 'TOLLS')) <> 'TOLLS' then
    raise exception 'Only toll transactions can be matched to customer rentals.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if v_rental.user_id is null then
    raise exception 'The selected rental has no customer account.';
  end if;
  if not public.rental_vehicle_possession_contains(
    v_rental.id, v_transaction.vehicle_id, v_transaction.occurred_at
  ) then
    raise exception 'The toll is outside this rental vehicle possession period.';
  end if;

  update public.tollspot_transactions
  set rental_id = v_rental.id,
      status = 'matched',
      match_method = 'admin',
      match_candidate_count = 1,
      review_reason = null,
      ignored_reason = null,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;

  return v_transaction;
end;
$$;

revoke all on function public.admin_match_tollspot_transaction(uuid, uuid) from public;
grant execute on function public.admin_match_tollspot_transaction(uuid, uuid)
  to authenticated;

-- Reconcile only unpaid duplicate rows. Paid duplicates are intentionally left
-- untouched because refunding settled Stripe payments requires owner approval.
create temporary table tollspot_duplicate_reconciliation on commit drop as
select
  duplicate.id as duplicate_charge_id,
  canonical.id as canonical_charge_id,
  duplicate.rental_id,
  duplicate.user_id,
  canonical.source_reference as tollspot_transaction_id
from public.rental_charge_items duplicate
join public.rental_charge_items canonical
  on canonical.source_type = 'tollspot'
 and canonical.source_reference = substring(
   coalesce(duplicate.description, '')
   from 'TollSpot transaction[[:space:]]+([A-Za-z0-9_-]+)'
 )
 and canonical.rental_id = duplicate.rental_id
where duplicate.id <> canonical.id
  and lower(coalesce(duplicate.charge_type, '')) = 'toll'
  and duplicate.source_type is null
  and duplicate.source_reference is null
  and lower(coalesce(duplicate.status, '')) in ('pending', 'failed');

update public.rental_charge_items duplicate
set
  status = 'waived',
  description = concat_ws(
    ' ', nullif(trim(duplicate.description), ''),
    '[Automatically waived: duplicate TollSpot charge; canonical charge '
      || reconciliation.canonical_charge_id || '.]'
  ),
  updated_at = now()
from tollspot_duplicate_reconciliation reconciliation
where duplicate.id = reconciliation.duplicate_charge_id;

insert into public.rental_audit_events (
  rental_id, user_id, actor_id, event_type, event_payload
)
select
  reconciliation.rental_id,
  reconciliation.user_id,
  null,
  'tollspot_duplicate_charge_auto_waived',
  jsonb_build_object(
    'duplicate_charge_id', reconciliation.duplicate_charge_id,
    'canonical_charge_id', reconciliation.canonical_charge_id,
    'tollspot_transaction_id', reconciliation.tollspot_transaction_id,
    'financial_action', 'none_unpaid_balance_only'
  )
from tollspot_duplicate_reconciliation reconciliation;

-- Always point the provider row at the canonical, idempotent TollSpot charge.
update public.tollspot_transactions toll
set
  rental_charge_item_id = canonical.id,
  status = case
    when lower(coalesce(canonical.status, '')) = 'paid' then 'paid'
    when lower(coalesce(canonical.status, '')) = 'waived' then 'ignored'
    else 'charge_created'
  end,
  review_reason = null,
  updated_at = now()
from public.rental_charge_items canonical
where canonical.source_type = 'tollspot'
  and canonical.source_reference = toll.tollspot_transaction_id
  and canonical.rental_id = toll.rental_id
  and (
    toll.rental_charge_item_id is distinct from canonical.id
    or lower(coalesce(toll.status, '')) is distinct from case
      when lower(coalesce(canonical.status, '')) = 'paid' then 'paid'
      when lower(coalesce(canonical.status, '')) = 'waived' then 'ignored'
      else 'charge_created'
    end
  );

create or replace function public.enforce_tollspot_charge_identity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_reference text;
begin
  if lower(coalesce(new.charge_type, '')) <> 'toll' then
    return new;
  end if;

  v_reference := substring(
    coalesce(new.description, '')
    from 'TollSpot transaction[[:space:]]+([A-Za-z0-9_-]+)'
  );
  if v_reference is null then return new; end if;

  if new.source_type is null and new.source_reference is null then
    new.source_type := 'tollspot';
    new.source_reference := v_reference;
  elsif new.source_type is distinct from 'tollspot'
      or new.source_reference is distinct from v_reference then
    raise exception 'TollSpot charge identity does not match its provider transaction.';
  end if;

  return new;
end;
$$;

drop trigger if exists rental_charges_enforce_tollspot_identity
  on public.rental_charge_items;
create trigger rental_charges_enforce_tollspot_identity
before insert or update of charge_type, description, source_type, source_reference
on public.rental_charge_items
for each row execute function public.enforce_tollspot_charge_identity();

-- Keep the legacy RPC idempotent for older admin clients, even though the new
-- portal no longer exposes a manual charge-creation button.
create or replace function public.admin_create_tollspot_charge(
  p_transaction_id uuid,
  p_taxable boolean default false
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  select * into v_transaction
  from public.tollspot_transactions
  where id = p_transaction_id
  for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;

  select * into v_charge
  from public.rental_charge_items
  where source_type = 'tollspot'
    and source_reference = v_transaction.tollspot_transaction_id
  limit 1;

  if found then
    update public.tollspot_transactions
    set
      rental_charge_item_id = v_charge.id,
      status = case
        when lower(coalesce(v_charge.status, '')) = 'paid' then 'paid'
        when lower(coalesce(v_charge.status, '')) = 'waived' then 'ignored'
        else 'charge_created'
      end,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_reason = null,
      updated_at = now()
    where id = p_transaction_id
    returning * into v_transaction;
    return v_transaction;
  end if;

  if v_transaction.status <> 'matched' or v_transaction.rental_id is null then
    raise exception 'Match the toll to a rental before creating a customer charge.';
  end if;

  select * into v_rental
  from public.rentals
  where id = v_transaction.rental_id
    and user_id is not null
    and lower(coalesce(status, '')) <> 'cancelled'
  for update;
  if not found then raise exception 'The matched rental is unavailable for billing.'; end if;

  insert into public.rental_charge_items (
    rental_id, user_id, name, charge_type, description, amount, taxable,
    tax_amount, total_amount, included_in_initial_payment, status,
    created_by, source_type, source_reference
  ) values (
    v_rental.id,
    v_rental.user_id,
    coalesce(nullif(trim(v_transaction.exit_location), ''),
      nullif(trim(v_transaction.road_or_plaza), ''), 'Toll charge'),
    'toll',
    concat_ws(' • ', nullif(trim(v_transaction.agency), ''),
      'TollSpot transaction ' || v_transaction.tollspot_transaction_id),
    round(v_transaction.total_amount, 2),
    false,
    0,
    round(v_transaction.total_amount, 2),
    false,
    'pending',
    auth.uid(),
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
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_reason = null,
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;

  return v_transaction;
end;
$$;

revoke all on function public.admin_create_tollspot_charge(uuid, boolean) from public;
grant execute on function public.admin_create_tollspot_charge(uuid, boolean)
  to authenticated;

-- Admins see only actual tolls tied to both a local fleet vehicle and a local
-- rental. Unmatched provider/Wheelbase records remain internal for retry and
-- audit, but cannot clutter the customer-facing operations queue.
create or replace view public.admin_tollspot_transactions
with (security_invoker = true)
as
select
  transaction.id,
  transaction.tollspot_transaction_id,
  transaction.tollspot_vehicle_id,
  transaction.vehicle_id,
  transaction.rental_id,
  transaction.occurred_at,
  transaction.posted_at,
  transaction.entry_at,
  transaction.entry_location,
  transaction.exit_location,
  transaction.agency,
  transaction.transaction_type,
  transaction.license_plate,
  transaction.license_plate_state,
  transaction.license_plate_country,
  case
    when nullif(transaction.transponder_number, '') is null then null
    else repeat('•', greatest(length(transaction.transponder_number) - 4, 0))
      || right(transaction.transponder_number, 4)
  end as masked_transponder,
  transaction.toll_amount,
  transaction.admin_fee,
  transaction.total_amount,
  transaction.currency,
  transaction.status,
  transaction.match_method,
  transaction.match_candidate_count,
  transaction.review_reason,
  transaction.ignored_reason,
  transaction.rental_charge_item_id,
  transaction.reviewed_by,
  transaction.reviewed_at,
  transaction.created_at,
  transaction.updated_at
from public.tollspot_transactions transaction
join public.vehicles vehicle
  on vehicle.id = transaction.vehicle_id
 and vehicle.tollspot_enabled
join public.rentals rental
  on rental.id = transaction.rental_id
 and lower(coalesce(rental.status, '')) <> 'cancelled'
where upper(coalesce(transaction.transaction_type, 'TOLLS')) = 'TOLLS';

grant select on public.admin_tollspot_transactions to authenticated;

comment on view public.admin_tollspot_transactions is
  'Admin-only TollSpot tolls connected to both a Rent Me CT vehicle and rental; unmatched external provider records stay internal.';

notify pgrst, 'reload schema';

commit;
