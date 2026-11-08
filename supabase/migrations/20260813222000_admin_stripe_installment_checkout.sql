begin;
-- Captured amounts and Stripe identifiers remain immutable. During the single
-- partially_paid -> paid transition, however, sync_rental_remaining_balance
-- must be allowed to record the provider of the final deposit-bearing payment.
create or replace function public.protect_captured_rental_payment_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.paid_at is not null
     or lower(coalesce(old.payment_status, '')) = 'paid' then
    new.payment_amount_cents := old.payment_amount_cents;
    new.stripe_payment_intent_id := old.stripe_payment_intent_id;
    new.stripe_customer_id := old.stripe_customer_id;
    new.payment_provider := old.payment_provider;
    new.paid_at := old.paid_at;
  elsif lower(coalesce(old.payment_status, '')) in ('partially_paid', 'partial') then
    new.payment_amount_cents := old.payment_amount_cents;
    new.stripe_payment_intent_id := old.stripe_payment_intent_id;
    new.stripe_customer_id := old.stripe_customer_id;
    new.paid_at := old.paid_at;
    if lower(coalesce(new.payment_status, '')) <> 'paid' then
      new.payment_provider := old.payment_provider;
    end if;
  end if;
  return new;
end;
$$;
-- Prepare one administrator-selected Stripe installment without changing the
-- canonical remaining-balance row. The temporary row becomes captured rental
-- money only after Stripe's webhook verifies the exact Checkout amount.
create or replace function public.prepare_admin_stripe_rental_installment(
  p_rental_id uuid,
  p_amount numeric,
  p_actor_id uuid
) returns public.rental_charge_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_settlement jsonb;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_balance_due numeric;
  v_protected_deposit numeric := 0;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  if p_actor_id is null or not exists (
    select 1 from public.profiles where id = p_actor_id and role = 'admin'
  ) then
    raise exception 'A valid administrator actor is required.';
  end if;
  if v_amount < 0.50 then raise exception 'Stripe installments must be at least $0.50.'; end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot receive a payment.';
  end if;

  v_settlement := public.sync_rental_remaining_balance(v_rental.id, p_actor_id);
  v_balance_due := round(coalesce((v_settlement->>'balance_due')::numeric, 0), 2);
  if v_balance_due <= 0 then raise exception 'This rental has no remaining balance.'; end if;
  if v_amount > v_balance_due + 0.005 then
    raise exception 'The Stripe payment exceeds the remaining rental balance of %.',
      to_char(v_balance_due, 'FM$999,999,990.00');
  end if;

  if lower(coalesce(v_rental.deposit_status, 'pending')) not in (
    'held', 'adjustment_refund_due', 'release_pending', 'released', 'transferred'
  ) then
    v_protected_deposit := greatest(0, coalesce(v_rental.security_deposit, 0));
  end if;
  if v_protected_deposit > 0 and v_balance_due < v_protected_deposit - 0.005 then
    raise exception 'The remaining balance is below the refundable deposit amount and requires administrator reconciliation before Stripe collection.';
  end if;
  if v_amount < v_balance_due - 0.005
     and v_balance_due - v_amount < v_protected_deposit - 0.005 then
    raise exception 'Leave the % security deposit for the final Stripe payment. The largest installment available now is %.',
      to_char(v_protected_deposit, 'FM$999,999,990.00'),
      to_char(greatest(0, v_balance_due - v_protected_deposit), 'FM$999,999,990.00');
  end if;

  if exists (
    select 1 from public.rental_charge_items
    where rental_id = v_rental.id
      and charge_type = 'rental_installment'
      and status = 'checkout_open'
  ) then
    raise exception 'Another Stripe installment checkout is already open for this rental.';
  end if;

  update public.rental_charge_items
  set status = 'waived',
      description = 'Superseded before Stripe Checkout was opened.',
      updated_at = now()
  where rental_id = v_rental.id
    and charge_type = 'rental_installment'
    and status in ('pending', 'failed');

  insert into public.rental_charge_items (
    rental_id, user_id, name, charge_type, description,
    amount, taxable, tax_amount, total_amount,
    included_in_initial_payment, status, created_by,
    source_type, source_reference, payment_amount_cents, payment_currency
  ) values (
    v_rental.id, v_rental.user_id,
    case when v_amount < v_balance_due - 0.005
      then 'Stripe rental installment' else 'Stripe rental balance payment' end,
    'rental_installment',
    case when v_amount < v_balance_due - 0.005
      then 'Administrator-selected Stripe installment toward the current rental balance.'
      else 'Administrator-selected Stripe payment for the complete current rental balance.' end,
    v_amount, false, 0, v_amount, false, 'pending', p_actor_id,
    case when v_protected_deposit > 0
      then 'admin_stripe_installment_deposit_pending'
      else 'admin_stripe_installment' end,
    gen_random_uuid()::text,
    round(v_amount * 100)::integer, 'usd'
  ) returning * into v_charge;

  return v_charge;
end;
$$;
revoke all on function public.prepare_admin_stripe_rental_installment(uuid,numeric,uuid)
  from public, anon, authenticated;
grant execute on function public.prepare_admin_stripe_rental_installment(uuid,numeric,uuid)
  to service_role;
-- Preserve the existing charge-settlement contract. A prepared installment is
-- promoted into the canonical rental balance ledger only after Stripe confirms
-- the exact Checkout session and PaymentIntent.
create or replace function public.record_stripe_rental_charge_payment(
  p_charge_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount_total integer,
  p_currency text
) returns public.rental_charge_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge public.rental_charge_items%rowtype;
  v_rental public.rentals%rowtype;
  v_expected integer;
  v_same_stripe_payment boolean;
  v_is_rental_installment boolean;
  v_is_partial_installment boolean := false;
  v_carries_deposit boolean := false;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  select * into v_charge from public.rental_charge_items where id = p_charge_id for update;
  if not found then raise exception 'Rental charge not found.'; end if;
  if v_charge.included_in_initial_payment then raise exception 'Initial booking fees are paid with the rental.'; end if;

  v_is_rental_installment := v_charge.charge_type = 'rental_installment'
    and v_charge.source_type in (
      'admin_stripe_installment', 'admin_stripe_installment_deposit_pending'
    );
  if v_charge.charge_type = 'rental_installment' and not v_is_rental_installment then
    raise exception 'This Stripe installment was not prepared by the protected admin workflow.';
  end if;
  v_expected := round(v_charge.total_amount * 100)::integer;
  if lower(coalesce(p_currency, 'usd')) <> 'usd' or p_amount_total <> v_expected then
    raise exception 'Stripe payment does not match the prepared charge amount.';
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

  if v_is_rental_installment then
    select exists (
      select 1 from public.rental_charge_items balance
      where balance.rental_id = v_charge.rental_id
        and balance.charge_type = 'rental_amendment'
        and balance.status in ('pending', 'checkout_open', 'failed')
        and balance.total_amount > v_charge.total_amount + 0.005
    ) into v_is_partial_installment;
    v_carries_deposit := v_charge.source_type = 'admin_stripe_installment_deposit_pending';
  end if;

  update public.rental_charge_items
  set charge_type = case when v_is_rental_installment then 'rental_amendment' else charge_type end,
      description = case when v_is_rental_installment
        then case when v_is_partial_installment
          then 'Stripe-confirmed installment credited toward the rental invoice.'
          else 'Stripe-confirmed payment credited toward the complete rental balance.' end
        else description end,
      status = 'paid',
      payment_provider = 'stripe',
      paid_at = now(),
      stripe_checkout_session_id = p_checkout_session_id,
      stripe_payment_intent_id = p_payment_intent_id,
      payment_amount_cents = p_amount_total,
      payment_currency = 'usd',
      last_admin_charge_error = null,
      updated_at = now()
  where id = v_charge.id
  returning * into v_charge;

  -- The balance-payment trigger has now recalculated the rental and, on the
  -- final payment, created its deposit allocation. Point that allocation at
  -- the final PaymentIntent so the deposit remains refundable through Stripe.
  if v_is_rental_installment and v_carries_deposit then
    select * into v_rental from public.rentals where id = v_charge.rental_id;
    if lower(coalesce(v_rental.payment_status, '')) = 'paid'
       and lower(coalesce(v_rental.deposit_status, '')) in ('held', 'adjustment_refund_due') then
      update public.rental_deposit_allocations
      set payment_provider = 'stripe',
          source_kind = 'initial_rental',
          stripe_payment_intent_id = p_payment_intent_id,
          updated_at = now()
      where holder_rental_id = v_charge.rental_id
        and status in ('held', 'refund_due_inspection', 'release_pending')
        and stripe_payment_intent_id is null;
    end if;
  end if;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_charge.rental_id, v_charge.user_id,
    case when v_is_rental_installment then v_charge.created_by else null end,
    case when v_is_rental_installment
      then case when v_is_partial_installment
        then 'stripe_rental_installment_paid' else 'stripe_rental_balance_paid' end
      else 'stripe_rental_charge_paid' end,
    jsonb_build_object(
      'charge_id', v_charge.id,
      'amount_total', p_amount_total,
      'installment', v_is_partial_installment,
      'deposit_bearing_payment', v_carries_deposit,
      'checkout_session_id', p_checkout_session_id,
      'payment_intent_id', p_payment_intent_id
    )
  );
  return v_charge;
end;
$$;
revoke all on function public.record_stripe_rental_charge_payment(uuid,text,text,integer,text)
  from public;
grant execute on function public.record_stripe_rental_charge_payment(uuid,text,text,integer,text)
  to service_role;
notify pgrst, 'reload schema';
commit;
