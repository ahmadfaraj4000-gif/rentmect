begin;

-- A paid or waived TollSpot charge is the source of truth for whether the
-- matching provider transaction can continue to protect a security deposit.
-- Keep both sides linked even when the charge was created before a later
-- TollSpot sync discovered the provider transaction.
create or replace function public.enforce_tollspot_status_from_linked_charge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge_status text;
begin
  if new.rental_charge_item_id is null then
    return new;
  end if;

  select lower(coalesce(charge.status, 'pending'))
  into v_charge_status
  from public.rental_charge_items charge
  where charge.id = new.rental_charge_item_id;

  if v_charge_status = 'paid' then
    new.status := 'paid';
    new.review_reason := null;
  elsif v_charge_status = 'waived' then
    new.status := 'ignored';
    new.review_reason := null;
    new.ignored_reason := coalesce(
      nullif(new.ignored_reason, ''),
      'Linked customer charge was waived by an administrator.'
    );
  elsif v_charge_status is not null
        and lower(coalesce(new.status, 'received')) in ('matched', 'charge_created') then
    new.status := 'charge_created';
    new.review_reason := null;
  end if;

  return new;
end;
$$;

drop trigger if exists tollspot_enforce_linked_charge_status
  on public.tollspot_transactions;
create trigger tollspot_enforce_linked_charge_status
before insert or update on public.tollspot_transactions
for each row execute function public.enforce_tollspot_status_from_linked_charge();

-- Repair historical rows that have a canonical TollSpot charge reference but
-- were never linked through rental_charge_item_id. This includes charges paid
-- before a later sync matched the provider transaction to the rental.
update public.tollspot_transactions toll
set
  rental_charge_item_id = charge.id,
  status = case
    when lower(coalesce(charge.status, '')) = 'paid' then 'paid'
    when lower(coalesce(charge.status, '')) = 'waived' then 'ignored'
    else 'charge_created'
  end,
  review_reason = null,
  ignored_reason = case
    when lower(coalesce(charge.status, '')) = 'waived' then coalesce(
      nullif(toll.ignored_reason, ''),
      'Linked customer charge was waived by an administrator.'
    )
    else toll.ignored_reason
  end,
  reviewed_at = coalesce(toll.reviewed_at, now()),
  updated_at = now()
from public.rental_charge_items charge
where charge.source_type = 'tollspot'
  and charge.rental_id = toll.rental_id
  and charge.source_reference = toll.tollspot_transaction_id
  and (
    toll.rental_charge_item_id is distinct from charge.id
    or lower(coalesce(toll.status, '')) is distinct from case
      when lower(coalesce(charge.status, '')) = 'paid' then 'paid'
      when lower(coalesce(charge.status, '')) = 'waived' then 'ignored'
      else 'charge_created'
    end
  );

-- Preserve every continuation-chain safeguard, but do not let a stale
-- provider-side status override a paid or waived canonical rental charge.
create or replace function public.rentmect_deposit_chain_release_blockers(
  p_rental_id uuid
) returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  with recursive ancestors as (
    select rental.id, rental.deposit_source_rental_id, rental.status,
           rental.inspection_completed_at
    from public.rentals rental
    where rental.id = p_rental_id
    union
    select parent.id, parent.deposit_source_rental_id, parent.status,
           parent.inspection_completed_at
    from public.rentals parent
    join ancestors child on parent.id = child.deposit_source_rental_id
  ), chain as (
    select rental.id, rental.deposit_source_rental_id, rental.status,
           rental.inspection_completed_at
    from public.rentals rental
    where rental.id in (select id from ancestors)
    union
    select child.id, child.deposit_source_rental_id, child.status,
           child.inspection_completed_at
    from public.rentals child
    join chain parent on child.deposit_source_rental_id = parent.id
  ), blockers as (
    select jsonb_build_object(
      'type', 'rental_not_completed', 'rental_id', chain.id,
      'detail', 'Every rental in the continuation chain must be completed.'
    ) as blocker
    from chain where lower(coalesce(chain.status, '')) <> 'completed'
    union all
    select jsonb_build_object(
      'type', 'inspection_incomplete', 'rental_id', chain.id,
      'detail', 'Every vehicle in the continuation chain must pass return inspection.'
    )
    from chain where chain.inspection_completed_at is null
    union all
    select jsonb_build_object(
      'type', 'unpaid_charge', 'rental_id', charge.rental_id,
      'detail', coalesce(charge.name, 'Outstanding rental charge')
    )
    from public.rental_charge_items charge
    where charge.rental_id in (select id from chain)
      and not charge.included_in_initial_payment
      and charge.status in ('pending', 'checkout_open', 'failed')
    union all
    select jsonb_build_object(
      'type', 'open_vehicle_report', 'rental_id', report.rental_id,
      'detail', coalesce(report.issue_type, report.report_type, 'Open vehicle report')
    )
    from public.vehicle_reports report
    where report.rental_id in (select id from chain)
      and lower(coalesce(report.status, 'open')) not in ('resolved', 'closed', 'completed')
    union all
    select jsonb_build_object(
      'type', 'unresolved_toll', 'rental_id', toll.rental_id,
      'detail', 'A TollSpot transaction still requires payment or resolution.'
    )
    from public.tollspot_transactions toll
    where toll.rental_id in (select id from chain)
      and lower(coalesce(toll.status, 'needs_review')) not in ('paid', 'ignored')
      and not exists (
        select 1
        from public.rental_charge_items charge
        where charge.rental_id = toll.rental_id
          and charge.source_type = 'tollspot'
          and (
            charge.id = toll.rental_charge_item_id
            or charge.source_reference = toll.tollspot_transaction_id
          )
          and lower(coalesce(charge.status, '')) in ('paid', 'waived')
      )
  )
  select coalesce(jsonb_agg(blocker), '[]'::jsonb) from blockers;
$$;

revoke all on function public.rentmect_deposit_chain_release_blockers(uuid)
  from public;
grant execute on function public.rentmect_deposit_chain_release_blockers(uuid)
  to service_role;

commit;
