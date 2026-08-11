-- Make every admin rental edit reconcile against the same payment ledger.
-- Captured money and deposits are immutable; edits only change the invoice.

alter table public.rental_amendments
  add column if not exists invoice_total_before numeric(10,2),
  add column if not exists invoice_total_after numeric(10,2),
  add column if not exists net_paid_at_amendment numeric(10,2),
  add column if not exists balance_due_before numeric(10,2),
  add column if not exists balance_due_after numeric(10,2),
  add column if not exists credit_due_after numeric(10,2),
  add column if not exists canonical_settlement_status text;

create or replace function public.capture_rental_amendment_settlement_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paid numeric;
begin
  new.invoice_total_before := round(coalesce((new.old_values ->> 'total')::numeric, 0), 2);
  new.invoice_total_after := round(coalesce((new.new_values ->> 'total')::numeric, 0), 2);
  v_paid := public.rentmect_rental_net_paid_amount(new.rental_id);
  new.net_paid_at_amendment := v_paid;
  new.balance_due_before := greatest(0, round(new.invoice_total_before - v_paid, 2));
  new.balance_due_after := greatest(0, round(new.invoice_total_after - v_paid, 2));
  new.credit_due_after := greatest(0, round(v_paid - new.invoice_total_after, 2));
  new.canonical_settlement_status := case
    when new.balance_due_after > 0.005 and v_paid > 0.005 then 'balance_due'
    when new.balance_due_after > 0.005 then 'payment_pending'
    when new.credit_due_after > 0.005 then 'credit_due'
    else 'settled'
  end;
  return new;
end;
$$;

drop trigger if exists rental_amendment_settlement_snapshot on public.rental_amendments;
create trigger rental_amendment_settlement_snapshot
before insert on public.rental_amendments
for each row execute function public.capture_rental_amendment_settlement_snapshot();

create or replace function public.protect_captured_rental_payment_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_captured boolean := old.paid_at is not null
    or lower(coalesce(old.payment_status, '')) in ('paid', 'partially_paid', 'partial');
begin
  if v_captured then
    if new.security_deposit is distinct from old.security_deposit then
      raise exception 'A captured rental deposit cannot be rewritten. Keep the original deposit and use the protected deposit refund or adjustment workflow.';
    end if;
    if coalesce(old.security_deposit, 0) > 0
       and lower(coalesce(new.deposit_status, '')) = 'waived'
       and lower(coalesce(old.deposit_status, '')) <> 'waived' then
      raise exception 'A captured rental deposit must be refunded or released, not marked waived.';
    end if;

    new.payment_amount_cents := old.payment_amount_cents;
    new.stripe_payment_intent_id := old.stripe_payment_intent_id;
    new.stripe_customer_id := old.stripe_customer_id;
    new.payment_provider := old.payment_provider;
    new.paid_at := old.paid_at;
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_protect_captured_payment_snapshot on public.rentals;
create trigger rentals_protect_captured_payment_snapshot
before update of payment_amount_cents, stripe_payment_intent_id,
  stripe_customer_id, payment_provider, paid_at, security_deposit, deposit_status
on public.rentals
for each row execute function public.protect_captured_rental_payment_snapshot();

create or replace function public.admin_preview_rental_amendment(
  p_rental_id uuid,
  p_vehicle_id uuid,
  p_pickup_date date,
  p_pickup_time text,
  p_return_date date,
  p_return_time text,
  p_daily_rate numeric default null,
  p_security_deposit numeric default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_preview jsonb;
  v_manual_discount numeric;
  v_new_rental numeric;
  v_new_tax numeric;
  v_new_pricing_total numeric;
  v_current_pricing_total numeric;
  v_new_total numeric;
  v_current_total numeric;
  v_pricing_delta numeric;
  v_total_delta numeric;
  v_requires_resign boolean;
  v_settlement_status text;
  v_paid numeric;
  v_old_balance numeric;
  v_new_balance numeric;
  v_credit numeric;
  v_canonical_status text;
begin
  v_preview := public.admin_preview_rental_amendment_without_manual_discount(
    p_rental_id, p_vehicle_id, p_pickup_date, p_pickup_time,
    p_return_date, p_return_time, p_daily_rate, p_security_deposit
  );

  select * into v_rental from public.rentals where id = p_rental_id;

  if (
    v_rental.paid_at is not null
    or lower(coalesce(v_rental.payment_status, '')) in ('paid', 'partially_paid', 'partial')
  ) and abs(
    coalesce((v_preview #>> '{new,security_deposit}')::numeric, 0)
      - coalesce(v_rental.security_deposit, 0)
  ) > 0.005 then
    raise exception 'The captured deposit must stay at %. Vehicle and schedule changes only reprice the rental portion.',
      to_char(coalesce(v_rental.security_deposit, 0), 'FM$999,999,990.00');
  end if;

  v_manual_discount := least(
    round(coalesce(v_rental.manual_discount_amount, 0), 2),
    round(coalesce((v_preview #>> '{new,rental_total}')::numeric, 0), 2)
  );

  if v_manual_discount > 0 then
    v_new_rental := round((v_preview #>> '{new,rental_total}')::numeric - v_manual_discount, 2);
    v_new_tax := round((v_new_rental + coalesce(v_rental.taxable_service_fee_total, 0)) * 0.0635, 2);
    v_new_pricing_total := round(
      v_new_rental + coalesce((v_preview #>> '{new,service_fee_total}')::numeric, 0) + v_new_tax, 2
    );
    v_current_pricing_total := round(
      coalesce((v_preview #>> '{old,rental_total}')::numeric, 0)
        + coalesce((v_preview #>> '{old,service_fee_total}')::numeric, 0)
        + coalesce((v_preview #>> '{old,tax_amount}')::numeric, 0), 2
    );
    v_new_total := round(v_new_pricing_total + (v_preview #>> '{new,security_deposit}')::numeric, 2);
    v_current_total := round(v_current_pricing_total + (v_preview #>> '{old,security_deposit}')::numeric, 2);
    v_pricing_delta := round(v_new_pricing_total - v_current_pricing_total, 2);
    v_total_delta := round(v_new_total - v_current_total, 2);
    v_requires_resign := coalesce((v_preview ->> 'requires_customer_resign')::boolean, false)
      or (coalesce(v_rental.agreement_signed, false)
        and lower(coalesce(v_rental.status, '')) <> 'completed'
        and abs(v_total_delta) > 0.005);
    v_settlement_status := case
      when lower(coalesce(v_rental.payment_status, 'pending')) <> 'paid' then 'unpaid_repriced'
      when v_total_delta > 0.005 then 'customer_charge_pending'
      when v_total_delta < -0.005 then 'customer_credit_due'
      else 'no_change'
    end;

    v_preview := jsonb_set(v_preview, '{new,rental_total}', to_jsonb(v_new_rental), true);
    v_preview := jsonb_set(v_preview, '{new,tax_amount}', to_jsonb(v_new_tax), true);
    v_preview := jsonb_set(v_preview, '{new,total}', to_jsonb(v_new_total), true);
    v_preview := jsonb_set(v_preview, '{new,manual_discount_amount}', to_jsonb(v_manual_discount), true);
    v_preview := jsonb_set(v_preview, '{new,pre_manual_discount_rental_total}',
      to_jsonb(round(v_new_rental + v_manual_discount, 2)), true);
    v_preview := jsonb_set(v_preview, '{pricing_delta}', to_jsonb(v_pricing_delta), true);
    v_preview := jsonb_set(v_preview, '{total_delta}', to_jsonb(v_total_delta), true);
    v_preview := jsonb_set(v_preview, '{requires_customer_resign}', to_jsonb(v_requires_resign), true);
    v_preview := jsonb_set(v_preview, '{settlement_status}', to_jsonb(v_settlement_status), true);
  end if;

  v_current_total := round(coalesce((v_preview #>> '{old,total}')::numeric, 0), 2);
  v_new_total := round(coalesce((v_preview #>> '{new,total}')::numeric, 0), 2);
  v_paid := public.rentmect_rental_net_paid_amount(p_rental_id);
  v_old_balance := greatest(0, round(v_current_total - v_paid, 2));
  v_new_balance := greatest(0, round(v_new_total - v_paid, 2));
  v_credit := greatest(0, round(v_paid - v_new_total, 2));
  v_canonical_status := case
    when v_new_balance > 0.005 and v_paid > 0.005 then 'balance_due'
    when v_new_balance > 0.005 then 'payment_pending'
    when v_credit > 0.005 then 'credit_due'
    else 'settled'
  end;

  return v_preview || jsonb_build_object(
    'net_paid', v_paid,
    'old_balance_due', v_old_balance,
    'balance_due', v_new_balance,
    'credit_due', v_credit,
    'balance_delta', round(v_new_balance - v_old_balance, 2),
    'canonical_settlement_status', v_canonical_status
  );
end;
$$;

revoke all on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) from public;
grant execute on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) to authenticated, service_role;

create or replace function public.add_canonical_settlement_to_amendment_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amendment public.rental_amendments%rowtype;
begin
  if new.event_type <> 'admin_rental_amended'
     or nullif(new.event_payload ->> 'amendment_id', '') is null then
    return new;
  end if;
  select * into v_amendment
  from public.rental_amendments
  where id = (new.event_payload ->> 'amendment_id')::uuid;
  if found then
    new.event_payload := new.event_payload || jsonb_build_object(
      'canonical_settlement_status', v_amendment.canonical_settlement_status,
      'invoice_total_before', v_amendment.invoice_total_before,
      'invoice_total_after', v_amendment.invoice_total_after,
      'net_paid', v_amendment.net_paid_at_amendment,
      'balance_due_before', v_amendment.balance_due_before,
      'balance_due_after', v_amendment.balance_due_after,
      'credit_due_after', v_amendment.credit_due_after
    );
  end if;
  return new;
end;
$$;

drop trigger if exists rental_amendment_canonical_audit on public.rental_audit_events;
create trigger rental_amendment_canonical_audit
before insert on public.rental_audit_events
for each row execute function public.add_canonical_settlement_to_amendment_audit();

create or replace function public.use_canonical_rental_amendment_email_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amendment public.rental_amendments%rowtype;
begin
  if new.email_type <> 'rental_amendment_notice' then return new; end if;
  select * into v_amendment
  from public.rental_amendments
  where rental_id = new.rental_id
  order by created_at desc, id desc
  limit 1;
  if not found then return new; end if;

  new.payload := new.payload || jsonb_build_object(
    'payment_update', case v_amendment.canonical_settlement_status
      when 'balance_due' then
        to_char(v_amendment.net_paid_at_amendment, 'FM$999,999,990.00')
          || ' remains credited. Only the remaining '
          || to_char(v_amendment.balance_due_after, 'FM$999,999,990.00')
          || ' is due for the revised rental.'
      when 'payment_pending' then
        'No payment has been received. The revised amount due is '
          || to_char(v_amendment.balance_due_after, 'FM$999,999,990.00') || '.'
      when 'credit_due' then
        'The revised rental has a customer credit of '
          || to_char(v_amendment.credit_due_after, 'FM$999,999,990.00')
          || ' for administrator review.'
      else 'The revised rental is fully settled; no additional payment is due.'
    end,
    'amount_paid', v_amendment.net_paid_at_amendment,
    'balance_due', v_amendment.balance_due_after,
    'credit_due', v_amendment.credit_due_after
  );
  return new;
end;
$$;

drop trigger if exists rental_amendment_canonical_email on public.email_outbox;
create trigger rental_amendment_canonical_email
before insert on public.email_outbox
for each row execute function public.use_canonical_rental_amendment_email_balance();

create or replace function public.record_stripe_rental_charge_payment(
  p_charge_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount_total integer,
  p_currency text
) returns public.rental_charge_items
language plpgsql security definer set search_path = public
as $$
declare
  v_charge public.rental_charge_items%rowtype;
  v_expected integer;
  v_same_stripe_payment boolean;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  select * into v_charge from public.rental_charge_items where id = p_charge_id for update;
  if not found then raise exception 'Rental charge not found.'; end if;
  if v_charge.included_in_initial_payment then raise exception 'Initial booking fees are paid with the rental.'; end if;

  v_expected := round(v_charge.total_amount * 100)::integer;
  if lower(coalesce(p_currency, 'usd')) <> 'usd' or p_amount_total <> v_expected then
    raise exception 'Stripe payment does not match the current rental balance.';
  end if;

  v_same_stripe_payment := lower(coalesce(v_charge.payment_provider, '')) = 'stripe'
    and (
      (nullif(v_charge.stripe_payment_intent_id, '') is not null
        and v_charge.stripe_payment_intent_id = nullif(p_payment_intent_id, ''))
      or (nullif(v_charge.stripe_checkout_session_id, '') is not null
        and v_charge.stripe_checkout_session_id = nullif(p_checkout_session_id, ''))
    );
  if v_charge.status = 'paid' then
    if v_same_stripe_payment then return v_charge; end if;
    raise exception 'This rental balance was already recorded through %. The Stripe capture requires reconciliation before the ledger can change.',
      coalesce(nullif(v_charge.external_payment_method, ''), nullif(v_charge.payment_provider, ''), 'another payment');
  end if;

  if coalesce(v_charge.stripe_checkout_session_id, '') like 'cs_%'
     and coalesce(p_checkout_session_id, '') like 'cs_%'
     and v_charge.stripe_checkout_session_id <> p_checkout_session_id then
    raise exception 'This Stripe Checkout is stale because the rental balance changed.';
  end if;

  update public.rental_charge_items set
    status = 'paid', payment_provider = 'stripe', paid_at = now(),
    stripe_checkout_session_id = p_checkout_session_id,
    stripe_payment_intent_id = p_payment_intent_id,
    payment_amount_cents = p_amount_total,
    payment_currency = 'usd', last_admin_charge_error = null, updated_at = now()
  where id = v_charge.id returning * into v_charge;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_charge.rental_id, v_charge.user_id, null, 'stripe_rental_charge_paid',
    jsonb_build_object('charge_id', v_charge.id, 'amount_total', p_amount_total,
      'checkout_session_id', p_checkout_session_id, 'payment_intent_id', p_payment_intent_id));
  return v_charge;
end;
$$;

revoke all on function public.record_stripe_rental_charge_payment(uuid, text, text, integer, text) from public;
grant execute on function public.record_stripe_rental_charge_payment(uuid, text, text, integer, text) to service_role;

notify pgrst, 'reload schema';
