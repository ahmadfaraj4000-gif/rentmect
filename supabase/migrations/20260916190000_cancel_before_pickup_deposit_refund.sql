-- An explicit cancellation credit preserves the original invoice and payment
-- history. Only the service refund workflow may authorize this exception to
-- the completed-return deposit gate. No existing booking is changed here.
alter table public.rentals
  add column if not exists cancelled_before_pickup_at timestamptz,
  add column if not exists cancellation_credit_amount numeric(12,2) not null default 0
    check (cancellation_credit_amount >= 0);

create or replace function public.protect_before_pickup_cancellation()
returns trigger language plpgsql set search_path = public as $$
begin
  if TG_OP='INSERT' then
    if new.cancelled_before_pickup_at is not null or new.cancellation_credit_amount<>0 then
      raise exception 'Cancellation credits must be issued through the guarded workflow.';
    end if;
    return new;
  end if;
  if (new.cancelled_before_pickup_at is distinct from old.cancelled_before_pickup_at
      or new.cancellation_credit_amount is distinct from old.cancellation_credit_amount)
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Use the guarded cancellation/refund workflow.';
  end if;
  if old.cancelled_before_pickup_at is not null and (
      new.status <> 'cancelled'
      or new.rental_total is distinct from old.rental_total
      or new.tax_amount is distinct from old.tax_amount
      or new.service_fee_total is distinct from old.service_fee_total
      or new.security_deposit is distinct from old.security_deposit) then
    raise exception 'A refunded cancellation cannot be reopened or repriced. Create a new reservation.';
  end if;
  return new;
end;
$$;
drop trigger if exists rentals_protect_before_pickup_cancellation on public.rentals;
create trigger rentals_protect_before_pickup_cancellation before insert or update on public.rentals
for each row execute function public.protect_before_pickup_cancellation();

create or replace function public.rentmect_rental_invoice_total(p_rental_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select greatest(0, round(coalesce(rental_total,0) + coalesce(service_fee_total,0)
    + coalesce(tax_amount,0) + coalesce(security_deposit,0) - cancellation_credit_amount, 2))
  from public.rentals where id=p_rental_id;
$$;

create or replace function public.prepare_before_pickup_deposit_refund(
  p_rental_id uuid, p_actor_id uuid, p_reason text
) returns public.rentals
language plpgsql security definer set search_path = public as $$
declare
  r public.rentals%rowtype;
  v_held numeric;
  v_refunded numeric;
  v_blockers jsonb;
begin
  if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Enter a cancellation reason of at least 5 characters.'; end if;
  if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then
    raise exception 'Admin access is required.';
  end if;
  select * into r from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if r.status='cancelled' and r.cancelled_before_pickup_at is not null then return r; end if;
  if r.status not in ('pending','documents_needed','document_review','ready_for_pickup','approved')
     or r.starting_mileage is not null or r.ending_mileage is not null then
    raise exception 'This action is only for a reservation cancelled before vehicle pickup.';
  end if;
  if r.payment_provider is distinct from 'stripe' or r.paid_at is null or r.payment_status <> 'paid' then
    raise exception 'This workflow requires a captured Stripe booking payment.';
  end if;
  if r.deposit_source_rental_id is not null or exists(
    select 1 from public.rentals where deposit_source_rental_id=r.id
  ) then raise exception 'This deposit protects a continuation booking. Resolve the continuation chain first.'; end if;
  perform 1 from public.rental_deposit_allocations
    where holder_rental_id=r.id or source_rental_id=r.id for update;
  if exists(select 1 from public.rental_deposit_allocations
    where (holder_rental_id=r.id or source_rental_id=r.id) and (
      holder_rental_id<>r.id or source_rental_id<>r.id or payment_provider<>'stripe'
      or stripe_payment_intent_id is distinct from r.stripe_payment_intent_id
      or status not in ('held','failed','refund_due_inspection'))) then
    raise exception 'Resolve the existing deposit allocation or refund before cancelling.';
  end if;
  select coalesce(sum(greatest(0,amount_held-amount_released)),0) into v_held
    from public.rental_deposit_allocations where holder_rental_id=r.id;
  if v_held <= 0 then raise exception 'No held Stripe deposit was found.'; end if;
  if exists(select 1 from public.rental_payment_refunds where rental_id=r.id
    and status in ('processing','pending')) then
    raise exception 'Wait for the existing rental refund to finish before cancelling.';
  end if;
  select coalesce(sum(amount),0) into v_refunded from public.rental_payment_refunds
    where rental_id=r.id and extension_request_id is null and status='succeeded';
  if abs(coalesce(r.payment_amount_cents,0)/100.0-v_refunded-v_held) > 0.005 then
    raise exception 'Refund the rental payment first using Refund. This action returns only the remaining security deposit.';
  end if;
  if exists(select 1 from public.rental_charge_items where rental_id=r.id and
    status not in ('waived','cancelled') and not (
      source_type='rental_balance' and charge_type='rental_amendment' and status in ('pending','failed'))) then
    raise exception 'Resolve additional charges and payment attempts before cancelling.';
  end if;
  if exists(select 1 from public.rental_extension_requests where rental_id=r.id
    and status not in ('cancelled','rejected','expired')) then
    raise exception 'Resolve the extension request before cancelling.';
  end if;
  -- Waive only the system balance created when the rental payment was refunded.
  -- Any later failure rolls this change back with the whole transaction.
  update public.rental_charge_items set status='waived', updated_at=now(),
    description='Rental cancelled before pickup; original invoice credited.'
    where rental_id=r.id and source_type='rental_balance'
      and charge_type='rental_amendment' and status in ('pending','failed');
  select coalesce(jsonb_agg(b), '[]'::jsonb) into v_blockers
    from jsonb_array_elements(public.rentmect_deposit_chain_release_blockers(r.id)) b
    where not (b->>'rental_id'=r.id::text and b->>'type' in ('rental_not_completed','inspection_incomplete'));
  if jsonb_array_length(v_blockers)>0 then
    raise exception 'Resolve deposit blockers before cancelling: %', v_blockers;
  end if;
  update public.rentals set status='cancelled', cancelled_at=now(), cancelled_by=p_actor_id,
    cancellation_reason=trim(p_reason), cancelled_before_pickup_at=now(),
    cancellation_credit_amount=round(coalesce(rental_total,0)+coalesce(service_fee_total,0)
      +coalesce(tax_amount,0)+coalesce(security_deposit,0),2),
    deposit_release_due_at=null, updated_at=now()
    where id=r.id returning * into r;
  update public.vehicles set status='available' where id=r.vehicle_id and status='reserved'
    and not exists(select 1 from public.rentals other where other.vehicle_id=r.vehicle_id
      and other.id<>r.id and other.status not in ('cancelled','completed'));
  insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
    values(r.id,r.user_id,p_actor_id,'admin_cancelled_before_pickup',jsonb_build_object(
      'reason',trim(p_reason),'cancellation_credit',r.cancellation_credit_amount,
      'deposit_refund_due',v_held,'rental_refunds_already_succeeded',v_refunded));
  return r;
end;
$$;
revoke all on function public.prepare_before_pickup_deposit_refund(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.prepare_before_pickup_deposit_refund(uuid,uuid,text) to service_role;

-- Deposit refunds are recorded in allocations, separately from rental refunds.
-- For this cancellation workflow both must reduce the remaining customer credit.
create or replace function public.rentmect_rental_net_paid_amount(p_rental_id uuid)
returns numeric language plpgsql stable security definer set search_path=public as $$
declare
  r public.rentals%rowtype;
  v_initial numeric:=0;
  v_balance numeric:=0;
  v_refunds numeric:=0;
  v_external numeric:=0;
  v_deposit numeric:=0;
begin
  select * into r from public.rentals where id=p_rental_id;
  if not found then return 0; end if;
  if r.paid_at is not null then v_initial:=greatest(0,coalesce(r.payment_amount_cents,0)/100.0); end if;
  select coalesce(sum(coalesce(payment_amount_cents,round(total_amount*100)::integer))/100.0,0)
    into v_balance from public.rental_charge_items where rental_id=r.id and charge_type='rental_amendment' and status='paid';
  select coalesce(sum(amount),0) into v_external from public.rental_external_payment_actions
    where rental_id=r.id and action_type='refund';
  select coalesce(sum(amount),0) into v_refunds from public.rental_payment_refunds
    where rental_id=r.id and extension_request_id is null and status in ('processing','pending','succeeded');
  if r.cancelled_before_pickup_at is not null then v_deposit:=coalesce(r.deposit_released_amount,0); end if;
  return greatest(0,round(v_initial+v_balance-v_refunds-v_external-v_deposit,2));
end;
$$;

-- No return inspection is required for a guarded cancellation before pickup.
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
           rental.inspection_completed_at, rental.cancelled_before_pickup_at
    from public.rentals rental
    where rental.id = p_rental_id
    union
    select parent.id, parent.deposit_source_rental_id, parent.status,
           parent.inspection_completed_at, parent.cancelled_before_pickup_at
    from public.rentals parent
    join ancestors child on parent.id = child.deposit_source_rental_id
  ), chain as (
    select rental.id, rental.deposit_source_rental_id, rental.status,
           rental.inspection_completed_at, rental.cancelled_before_pickup_at
    from public.rentals rental
    where rental.id in (select id from ancestors)
    union
    select child.id, child.deposit_source_rental_id, child.status,
           child.inspection_completed_at, child.cancelled_before_pickup_at
    from public.rentals child
    join chain parent on child.deposit_source_rental_id = parent.id
  ), blockers as (
    select jsonb_build_object(
      'type', 'rental_not_completed', 'rental_id', chain.id,
      'detail', 'Every rental in the continuation chain must be completed.'
    ) as blocker
    from chain where lower(coalesce(chain.status, '')) <> 'completed'
      and not (chain.status='cancelled' and chain.cancelled_before_pickup_at is not null)
    union all
    select jsonb_build_object(
      'type', 'inspection_incomplete', 'rental_id', chain.id,
      'detail', 'Every vehicle in the continuation chain must pass return inspection.'
    )
    from chain where chain.inspection_completed_at is null
      and not (chain.status='cancelled' and chain.cancelled_before_pickup_at is not null)
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
