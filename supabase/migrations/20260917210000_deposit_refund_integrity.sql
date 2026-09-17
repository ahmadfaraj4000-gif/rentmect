-- Deposit totals describe actual allocations, not historical external receipts.
-- Historical external refund records remain unchanged and separately auditable.
alter table public.rental_deposit_allocations
  add column if not exists refund_requested_at timestamptz,
  add column if not exists refund_completed_at timestamptz,
  add column if not exists external_receipt_refunded_amount numeric not null default 0;

alter table public.rental_deposit_allocations
  add constraint deposit_release_within_allocation check (amount_released <= amount_held),
  add constraint released_deposit_is_fully_returned check (status <> 'released' or amount_released = amount_held),
  add constraint external_receipt_release_within_allocation check (
    external_receipt_refunded_amount >= 0 and external_receipt_refunded_amount <= amount_released);

create unique index if not exists rental_deposit_allocations_refund_unique
on public.rental_deposit_allocations(refund_id) where refund_id is not null;

-- Only backfill dates supported by a completed-return timestamp, never a
-- general rental updated_at timestamp. Unknown historical dates remain unknown.
update public.rental_deposit_allocations a
set refund_completed_at=r.deposit_released_at,
    refund_requested_at=r.deposit_released_at
from public.rentals r where r.id=a.holder_rental_id
  and a.status='released' and a.amount_released>0 and r.deposit_released_at is not null;

-- Link a historical external receipt only when both amount and event time
-- exactly identify the local allocation update (no inference from a booking edit).
update public.rental_deposit_allocations a
set external_receipt_refunded_amount=e.deposit_amount_returned,
    refund_completed_at=e.created_at, refund_requested_at=e.created_at
from public.rental_external_payment_actions e
where e.rental_id=a.holder_rental_id and e.action_type='refund'
  and a.payment_provider='local' and a.amount_released>0
  and e.deposit_amount_returned=a.amount_released and e.created_at=a.updated_at
  and (select count(*) from public.rental_deposit_allocations x
       where x.holder_rental_id=a.holder_rental_id and x.payment_provider='local' and x.amount_released>0)=1;

create or replace function public.sync_deposit_released_total(p_rental_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_released numeric;
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  select coalesce(sum(amount_released),0) into v_released
    from public.rental_deposit_allocations where holder_rental_id=p_rental_id;
  update public.rentals set deposit_released_amount=v_released
    where id=p_rental_id and deposit_released_amount is distinct from v_released;
end;
$$;
revoke all on function public.sync_deposit_released_total(uuid) from public,anon,authenticated;
grant execute on function public.sync_deposit_released_total(uuid) to service_role;

create or replace function public.capture_deposit_refund_transition()
returns trigger language plpgsql set search_path=public as $$
begin
  if TG_OP='UPDATE' then
    -- A replayed pending webhook cannot undo a completed refund.
    if old.status='released' and old.refund_id is not null
       and new.refund_id=old.refund_id then
      new.status:=old.status;
      new.amount_released:=old.amount_released;
      new.last_error:=old.last_error;
    end if;
    if new.external_receipt_refunded_amount<old.external_receipt_refunded_amount then
      raise exception 'An external receipt refund attribution cannot be removed by an ordinary update.';
    end if;
    if new.amount_released<old.amount_released then
      raise exception 'A recorded deposit return cannot be reduced by an ordinary update.';
    end if;
    new.refund_requested_at:=old.refund_requested_at;
    new.refund_completed_at:=old.refund_completed_at;
    if ((new.refund_id is not null and new.refund_id is distinct from old.refund_id)
        or (new.status='release_pending' and new.status is distinct from old.status) or new.amount_released>old.amount_released)
      and new.refund_requested_at is null then new.refund_requested_at:=now(); end if;
    if new.amount_released>old.amount_released then new.refund_completed_at:=now(); end if;
  else
    if new.refund_id is not null or new.status='release_pending' or new.amount_released>0 then
      new.refund_requested_at:=coalesce(new.refund_requested_at,now());
    end if;
    if new.amount_released>0 then new.refund_completed_at:=coalesce(new.refund_completed_at,now()); end if;
  end if;
  return new;
end;
$$;
create trigger capture_deposit_refund_transition before insert or update
on public.rental_deposit_allocations for each row execute function public.capture_deposit_refund_transition();

create or replace function public.sync_deposit_released_total_trigger()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if TG_OP<>'INSERT' then perform public.sync_deposit_released_total(old.holder_rental_id); end if;
  if TG_OP<>'DELETE' and (TG_OP='INSERT' or new.holder_rental_id is distinct from old.holder_rental_id) then
    perform public.sync_deposit_released_total(new.holder_rental_id);
  end if;
  return null;
end;
$$;
create trigger sync_deposit_released_total_after_allocation after insert or update or delete
on public.rental_deposit_allocations for each row execute function public.sync_deposit_released_total_trigger();

-- A second layer rejects inconsistent totals even from future code paths.
-- Deferred validation permits a transaction to update the allocation and its
-- summary in either order, but never commit an inconsistent result.
create or replace function public.check_deposit_released_total()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_actual numeric; v_summary numeric;
begin
  select coalesce(deposit_released_amount,0) into v_summary from public.rentals where id=new.id;
  if not found then return null; end if;
  select coalesce(sum(amount_released),0) into v_actual from public.rental_deposit_allocations where holder_rental_id=new.id;
  if abs(v_summary-v_actual)>0.005 then
    raise exception 'Deposit released total must match recorded deposit allocations (rental %).',new.id;
  end if;
  return null;
end;
$$;
create constraint trigger check_deposit_released_total after insert or update of deposit_released_amount
on public.rentals deferrable initially deferred for each row execute function public.check_deposit_released_total();

CREATE OR REPLACE FUNCTION public.admin_adjust_external_rental_payment(p_rental_id uuid, p_payment_charge_id uuid DEFAULT NULL::uuid, p_action_type text DEFAULT NULL::text, p_replacement_method text DEFAULT NULL::text, p_reference text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_action text := lower(trim(coalesce(p_action_type, '')));
  v_method text := lower(trim(coalesce(p_replacement_method, '')));
  v_reason text := trim(coalesce(p_reason, ''));
  v_original_method text;
  v_amount numeric(12,2);
  v_paid_before numeric(12,2);
  v_paid_after numeric(12,2);
  v_invoice_without_deposit numeric(12,2);
  v_deposit_before numeric(12,2);
  v_deposit_after numeric(12,2);
  v_deposit_returned numeric(12,2) := 0;
  v_remaining_release numeric(12,2) := 0;
  v_available numeric(12,2);
  v_release numeric(12,2);
  v_allocation public.rental_deposit_allocations%rowtype;
  v_action_row public.rental_external_payment_actions%rowtype;
  v_settlement jsonb;
begin
  if v_actor_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if v_action not in ('method_correction', 'refund') then
    raise exception 'Choose method correction or refund.';
  end if;
  if length(v_reason) < 5 then
    raise exception 'Enter an audit reason of at least five characters.';
  end if;
  if v_action = 'method_correction'
     and not coalesce(public.rentmect_has_permission('payment.collect'), false) then
    raise exception 'Payment collection permission is required.';
  end if;
  if v_action = 'refund'
     and not coalesce(public.rentmect_has_permission('payment.refund'), false) then
    raise exception 'Payment refund permission is required.';
  end if;
  if v_action = 'method_correction'
     and v_method not in ('card', 'terminal', 'cash_app', 'cash', 'bank_transfer', 'other') then
    raise exception 'Choose the corrected external payment method.';
  end if;

  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;

  if p_payment_charge_id is null then
    if lower(coalesce(v_rental.payment_provider, '')) <> 'local' or v_rental.paid_at is null then
      raise exception 'The original rental receipt was not recorded as an external payment.';
    end if;
    if exists (
      select 1 from public.rental_external_payment_actions
      where rental_id = v_rental.id and payment_charge_id is null and action_type = 'refund'
    ) then raise exception 'This external receipt was already refunded.'; end if;
    v_original_method := v_rental.external_payment_method;
    v_amount := round(coalesce(v_rental.payment_amount_cents, 0) / 100.0, 2);
    if v_amount <= 0 then v_amount := public.rentmect_rental_invoice_total(v_rental.id); end if;
  else
    select * into v_charge
    from public.rental_charge_items
    where id = p_payment_charge_id and rental_id = p_rental_id
    for update;
    if not found then raise exception 'External payment receipt not found.'; end if;
    if v_charge.charge_type <> 'rental_amendment'
       or lower(coalesce(v_charge.payment_provider, '')) <> 'local'
       or v_charge.status <> 'paid' then
      raise exception 'Only a paid external rental-balance receipt can be edited.';
    end if;
    if exists (
      select 1 from public.rental_external_payment_actions
      where rental_id = v_rental.id
        and payment_charge_id = v_charge.id
        and action_type = 'refund'
    ) then raise exception 'This external receipt was already refunded.'; end if;
    v_original_method := v_charge.external_payment_method;
    v_amount := round(coalesce(v_charge.payment_amount_cents, round(v_charge.total_amount * 100)::integer) / 100.0, 2);
  end if;

  if v_action = 'method_correction' then
    if v_method = lower(coalesce(v_original_method, '')) then
      raise exception 'Choose a different payment method.';
    end if;
    if p_payment_charge_id is null then
      update public.rentals
      set external_payment_method = v_method,
          updated_at = now()
      where id = v_rental.id;
    else
      update public.rental_charge_items
      set external_payment_method = v_method,
          external_payment_reference = nullif(trim(coalesce(p_reference, '')), ''),
          updated_at = now()
      where id = v_charge.id;
    end if;

    insert into public.rental_external_payment_actions (
      rental_id, payment_charge_id, source_kind, action_type, amount,
      original_method, replacement_method, reference, reason, created_by
    ) values (
      v_rental.id, p_payment_charge_id,
      case when p_payment_charge_id is null then 'rental' else 'rental_charge' end,
      'method_correction', v_amount, v_original_method, v_method,
      nullif(trim(coalesce(p_reference, '')), ''), v_reason, v_actor_id
    ) returning * into v_action_row;
  else
    v_paid_before := public.rentmect_rental_net_paid_amount(v_rental.id);
    if p_payment_charge_id is null then
      insert into public.rental_external_payment_actions (
        rental_id, payment_charge_id, source_kind, action_type, amount,
        original_method, reference, reason, created_by
      ) values (
        v_rental.id, null, 'rental', 'refund', v_amount,
        v_original_method, nullif(trim(coalesce(p_reference, '')), ''), v_reason, v_actor_id
      ) returning * into v_action_row;
    else
      insert into public.rental_external_payment_actions (
        rental_id, payment_charge_id, source_kind, action_type, amount,
        original_method, reference, reason, created_by
      ) values (
        v_rental.id, v_charge.id, 'rental_charge', 'refund', v_amount,
        v_original_method, nullif(trim(coalesce(p_reference, '')), ''), v_reason, v_actor_id
      ) returning * into v_action_row;
    end if;

    v_paid_after := public.rentmect_rental_net_paid_amount(v_rental.id);
    v_invoice_without_deposit := greatest(0, public.rentmect_rental_invoice_total(v_rental.id) - coalesce(v_rental.security_deposit, 0));
    v_deposit_before := least(coalesce(v_rental.security_deposit, 0), greatest(0, v_paid_before - v_invoice_without_deposit));
    v_deposit_after := least(coalesce(v_rental.security_deposit, 0), greatest(0, v_paid_after - v_invoice_without_deposit));
    v_deposit_returned := greatest(0, round(v_deposit_before - v_deposit_after, 2));
    -- A Stripe allocation is never returned by recording an external receipt.
    -- Without allocations, retain the historical receipt classification only.
    if exists(select 1 from public.rental_deposit_allocations where holder_rental_id=v_rental.id) then
      select least(v_deposit_returned,coalesce(sum(greatest(0,amount_held-amount_released)),0))
        into v_deposit_returned from public.rental_deposit_allocations
        where holder_rental_id=v_rental.id and source_rental_id=v_rental.id
          and payment_provider='local' and status in ('held','refund_due_inspection','failed');
    end if;
    v_remaining_release := v_deposit_returned;

    for v_allocation in
      select * from public.rental_deposit_allocations
      where holder_rental_id = v_rental.id
        and source_rental_id = v_rental.id
        and payment_provider = 'local'
        and status in ('held', 'refund_due_inspection', 'failed')
      order by created_at, id
      for update
    loop
      exit when v_remaining_release <= 0.005;
      v_available := greatest(0, v_allocation.amount_held - v_allocation.amount_released);
      v_release := least(v_available, v_remaining_release);
      update public.rental_deposit_allocations
      set amount_released = amount_released + v_release,
          external_receipt_refunded_amount = external_receipt_refunded_amount + v_release,
          status = case when amount_released + v_release >= amount_held - 0.005 then 'released' else status end,
          last_error = null,
          updated_at = now()
      where id = v_allocation.id;
      v_remaining_release := greatest(0, v_remaining_release - v_release);
    end loop;

    -- Never add an estimated receipt portion to the current deposit total.
    -- The allocation trigger derives released amounts from actual releases.
    perform public.sync_deposit_released_total(v_rental.id);
    if exists(select 1 from public.rental_deposit_allocations where holder_rental_id=v_rental.id) then
      update public.rentals set deposit_held_amount=(select coalesce(sum(greatest(0,amount_held-amount_released)),0)
        from public.rental_deposit_allocations where holder_rental_id=v_rental.id),
        deposit_status=case when (select coalesce(sum(greatest(0,amount_held-amount_released)),0)
          from public.rental_deposit_allocations where holder_rental_id=v_rental.id)<=0.005 then 'pending' else deposit_status end
        where id=v_rental.id;
    end if;

    update public.rental_external_payment_actions
    set deposit_amount_returned = v_deposit_returned
    where id = v_action_row.id
    returning * into v_action_row;
  end if;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id, v_rental.user_id, v_actor_id,
    case when v_action = 'refund' then 'admin_external_payment_refunded'
      else 'admin_external_payment_method_corrected' end,
    jsonb_build_object(
      'action_id', v_action_row.id,
      'payment_charge_id', p_payment_charge_id,
      'amount', v_amount,
      'original_method', v_original_method,
      'replacement_method', nullif(v_method, ''),
      'reference', nullif(trim(coalesce(p_reference, '')), ''),
      'reason', v_reason,
      'money_actually_returned', v_action = 'refund',
      'deposit_amount_returned', v_deposit_returned
    )
  );
  perform public.record_admin_audit_event(
    case when v_action = 'refund' then 'payment.external_refunded'
      else 'payment.external_method_corrected' end,
    'rental', v_rental.id::text,
    jsonb_build_object('action_id', v_action_row.id, 'payment_charge_id', p_payment_charge_id,
      'amount', v_amount, 'reason', v_reason, 'money_actually_returned', v_action = 'refund')
  );

  v_settlement := public.sync_rental_remaining_balance(v_rental.id, v_actor_id);
  perform public.sync_deposit_action_task(v_rental.id);
  return v_settlement || jsonb_build_object('action', to_jsonb(v_action_row));
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_record_local_deposit_release(p_rental_id uuid)
 RETURNS rentals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_released numeric := 0;
  v_remaining numeric := 0;
  v_blockers jsonb := '[]'::jsonb;
begin
  if coalesce(public.rentmect_has_permission('deposit.resolve'), false) is not true then
    raise exception 'Deposit resolution permission is required.';
  end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) <> 'completed' then
    raise exception 'The deposit can be returned only after the rental is completed.';
  end if;

  v_blockers := public.rentmect_deposit_chain_release_blockers(v_rental.id);
  if jsonb_array_length(v_blockers) > 0 then
    raise exception 'Deposit release is blocked by the continuation chain: %', v_blockers::text;
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
      deposit_released_amount = (select coalesce(sum(amount_released),0) from public.rental_deposit_allocations where holder_rental_id=v_rental.id),
      deposit_status = case when v_remaining <= 0 then 'released' else deposit_status end,
      deposit_released_at = case when v_remaining <= 0 then now() else deposit_released_at end,
      deposit_release_reason = 'External deposit return recorded after continuation-chain validation.',
      deposit_decrease_refund_due = case when v_remaining <= 0 then 0 else deposit_decrease_refund_due end,
      updated_at = now()
  where id = v_rental.id returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_local_deposit_release_recorded',
    jsonb_build_object('amount', v_released, 'continuation_chain_checked', true));
  return v_rental;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ensure_rental_deposit_allocation(p_rental_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rental public.rentals%rowtype;
  v_active numeric := 0;
  v_expected numeric := 0;
  v_missing numeric := 0;
  v_non_deposit_invoice numeric := 0;
  v_source_capture numeric := 0;
  v_proven_captured_deposit numeric := 0;
  v_source_payment_intent_id text;
  v_linked integer := 0;
begin
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.deposit_status, '')) <> 'held' then return; end if;

  perform public.sync_deposit_released_total(v_rental.id);

  v_non_deposit_invoice := greatest(
    0,
    coalesce(v_rental.rental_total, 0)
      + coalesce(v_rental.service_fee_total, 0)
      + coalesce(v_rental.tax_amount, 0)
  );

  if lower(coalesce(v_rental.payment_provider, '')) = 'stripe'
     and nullif(trim(coalesce(v_rental.stripe_payment_intent_id, '')), '') is not null
     and v_rental.paid_at is not null then
    v_source_payment_intent_id := v_rental.stripe_payment_intent_id;
    v_source_capture := greatest(0, coalesce(v_rental.payment_amount_cents, 0) / 100.0);
  else
    select
      stripe_payment_intent_id,
      greatest(0, coalesce(payment_amount_cents, round(total_amount * 100)::integer) / 100.0)
    into v_source_payment_intent_id, v_source_capture
    from public.rental_charge_items
    where rental_id = v_rental.id
      and charge_type = 'rental_amendment'
      and status = 'paid'
      and lower(coalesce(payment_provider, '')) = 'stripe'
      and nullif(trim(coalesce(stripe_payment_intent_id, '')), '') is not null
    order by paid_at desc nulls last, created_at desc
    limit 1;
  end if;

  if nullif(trim(coalesce(v_source_payment_intent_id, '')), '') is not null then
    v_proven_captured_deposit := least(
      greatest(0, coalesce(v_rental.security_deposit, 0)),
      greatest(0, round(v_source_capture - v_non_deposit_invoice, 2))
    );
  end if;

  v_expected := greatest(
    0,
    coalesce(v_rental.deposit_held_amount, 0),
    v_proven_captured_deposit
  );

  if v_proven_captured_deposit > 0.005
    and not exists(select 1 from public.rental_deposit_allocations where stripe_payment_intent_id=v_source_payment_intent_id)
    and (select coalesce(sum(amount_held),0) from public.rental_deposit_allocations
      where holder_rental_id=v_rental.id and source_rental_id=v_rental.id
        and status in ('held','refund_due_inspection','failed') and stripe_payment_intent_id is null)<=v_proven_captured_deposit then
    update public.rental_deposit_allocations
    set payment_provider = 'stripe',
        source_kind = 'initial_rental',
        stripe_payment_intent_id = v_source_payment_intent_id,
        last_error = null,
        updated_at = now()
    where holder_rental_id = v_rental.id
      and source_rental_id = v_rental.id
      and status in ('held', 'refund_due_inspection', 'failed')
      and nullif(trim(coalesce(stripe_payment_intent_id, '')), '') is null;
    get diagnostics v_linked = row_count;
  end if;

  select coalesce(sum(greatest(0, amount_held - amount_released)), 0)
  into v_active
  from public.rental_deposit_allocations
  where holder_rental_id = p_rental_id
    and status in ('held', 'refund_due_inspection', 'release_pending', 'failed');

  v_missing := greatest(0, round(v_expected - v_active, 2));
  -- Released or transferred allocations still consume their original capture.
  -- Never reconstruct a second deposit from that same Stripe payment.
  if v_source_payment_intent_id is not null then
    v_missing := least(v_missing,greatest(0,v_proven_captured_deposit - (
      select coalesce(sum(amount_held),0) from public.rental_deposit_allocations
      where stripe_payment_intent_id=v_source_payment_intent_id)));
  end if;
  if v_missing > 0.005 then
    insert into public.rental_deposit_allocations (
      holder_rental_id, source_rental_id, source_kind, payment_provider,
      stripe_payment_intent_id, amount_held
    ) values (
      v_rental.id,
      v_rental.id,
      case when v_proven_captured_deposit > 0.005 then 'initial_rental' else 'local_payment' end,
      case when v_proven_captured_deposit > 0.005 then 'stripe' else 'local' end,
      case when v_proven_captured_deposit > 0.005 then v_source_payment_intent_id else null end,
      v_missing
    );
  end if;

  if v_linked > 0 or v_missing > 0.005 then
    update public.rentals
    set deposit_held_amount = greatest(coalesce(deposit_held_amount, 0), v_expected),
        deposit_release_error = null,
        updated_at = now()
    where id = v_rental.id;

    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    ) values (
      v_rental.id,
      v_rental.user_id,
      auth.uid(),
      'legacy_stripe_deposit_payment_intent_linked',
      jsonb_build_object(
        'payment_intent_id', v_source_payment_intent_id,
        'captured_amount', v_source_capture,
        'non_deposit_invoice_amount', v_non_deposit_invoice,
        'proven_deposit_amount', v_proven_captured_deposit,
        'allocations_linked', v_linked,
        'allocation_created', v_missing
      )
    );
  end if;
end;
$function$;


-- Repair only the proven stale-summary pattern: no allocation was released,
-- no Stripe refund was recorded, and the discrepancy exactly matches the
-- separately retained external-return history. Keep a before/after audit.
with affected as (
  select r.id,r.user_id,r.deposit_released_amount old_amount
  from public.rentals r
  join (select holder_rental_id,sum(amount_released) released from public.rental_deposit_allocations group by holder_rental_id) a on a.holder_rental_id=r.id
  join (select rental_id,sum(deposit_amount_returned) returned from public.rental_external_payment_actions where action_type='refund' group by rental_id) e on e.rental_id=r.id
  where r.deposit_status='held' and r.deposit_refund_id is null
    and a.released=0 and r.deposit_released_amount>0 and r.deposit_released_amount=e.returned
), repaired as (
  update public.rentals r set deposit_released_amount=0 from affected a where r.id=a.id
  returning r.id,r.user_id,a.old_amount
)
insert into public.rental_audit_events(rental_id,user_id,event_type,event_payload)
select id,user_id,'deposit_summary_integrity_repaired',jsonb_build_object(
  'previous_released_total',old_amount,'corrected_released_total',0,
  'reason','Historical external receipt refund was incorrectly carried into current allocation totals.',
  'external_refund_history_preserved',true,'money_moved',false)
from repaired;

-- Deploy must fail if any unexplained mismatch remains.
do $$ begin
  if exists(select 1 from public.rentals r where coalesce(r.deposit_released_amount,0)<>
    (select coalesce(sum(a.amount_released),0) from public.rental_deposit_allocations a where a.holder_rental_id=r.id)) then
    raise exception 'Unexplained deposit summary mismatch requires review before deployment.';
  end if;
end; $$;

-- Persist the refund and its summary in one transaction. A failed request must
-- not leave allocation and booking status disagreeing between HTTP calls.
create or replace function public.refresh_rental_deposit_summary(p_rental_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r public.rentals%rowtype;
  v_held numeric; v_released numeric; v_pending boolean; v_failed boolean;
  v_completed timestamptz; v_refund text; v_status text;
begin
  select * into r from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if not exists(select 1 from public.rental_deposit_allocations where holder_rental_id=r.id) then return null; end if;
  select coalesce(sum(greatest(0,amount_held-amount_released)),0),coalesce(sum(amount_released),0),
    bool_or(status='release_pending'),bool_or(status='failed'),max(refund_completed_at)
    into v_held,v_released,v_pending,v_failed from public.rental_deposit_allocations where holder_rental_id=r.id;
  select refund_id into v_refund from public.rental_deposit_allocations where holder_rental_id=r.id and refund_id is not null
    order by refund_completed_at desc nulls last,refund_requested_at desc nulls last,id limit 1;
  v_status:=case when v_held<=0.005 then 'released' when v_pending then 'release_pending'
    when coalesce(r.deposit_decrease_refund_due,0)>0 then 'adjustment_refund_due' else 'held' end;
  update public.rentals set deposit_status=v_status,deposit_held_amount=v_held,deposit_released_amount=v_released,
    deposit_refund_id=v_refund,deposit_release_due_at=null,
    deposit_released_at=case when v_held<=0.005 then v_completed else null end,
    deposit_decrease_refund_due=case when v_held<=0.005 then 0 else deposit_decrease_refund_due end,
    deposit_release_error=case when v_failed then 'One or more deposit refund allocations failed.' else null end
    where id=r.id;
  return jsonb_build_object('status',v_status,'unreleased',v_held,'released',v_released);
end;
$$;
revoke all on function public.refresh_rental_deposit_summary(uuid) from public,anon,authenticated;
grant execute on function public.refresh_rental_deposit_summary(uuid) to service_role;

create or replace function public.apply_stripe_deposit_refund(
  p_rental_id uuid,p_allocation_id uuid,p_refund_id text,p_payment_intent_id text,
  p_status text,p_amount numeric,p_failure_reason text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.rental_deposit_allocations%rowtype;
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  select * into a from public.rental_deposit_allocations where id=p_allocation_id and holder_rental_id=p_rental_id for update;
  if not found then raise exception 'Deposit allocation not found.'; end if;
  if a.payment_provider<>'stripe' or p_payment_intent_id is null
    or a.stripe_payment_intent_id is distinct from p_payment_intent_id then
    raise exception 'Stripe refund does not match the deposit payment source.';
  end if;
  if nullif(trim(p_refund_id),'') is null or p_amount is null or p_amount<=0 or p_amount>a.amount_held then
    raise exception 'Invalid deposit refund reference or amount.';
  end if;
  if a.refund_id is not null and a.refund_id<>p_refund_id then
    raise exception 'This allocation already has a different refund reference; reconcile it before changing refunds.';
  end if;
  update public.rental_deposit_allocations set refund_id=p_refund_id,
    status=case when p_status='succeeded' then 'released' when p_status in ('failed','canceled') then 'failed' else 'release_pending' end,
    amount_released=case when p_status='succeeded' then p_amount else 0 end,
    last_error=case when p_status in ('failed','canceled') then coalesce(p_failure_reason,'Stripe refund '||p_status) else null end,
    updated_at=now() where id=a.id;
  return public.refresh_rental_deposit_summary(p_rental_id);
end;
$$;
revoke all on function public.apply_stripe_deposit_refund(uuid,uuid,text,text,text,numeric,text) from public,anon,authenticated;
grant execute on function public.apply_stripe_deposit_refund(uuid,uuid,text,text,text,numeric,text) to service_role;
