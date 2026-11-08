begin;
-- Additive installment support for administrator-recorded external payments.
-- Full rental Checkout, refunds, deposits, extensions, and additional charges
-- retain their existing paths. Installments reuse the canonical rental-balance
-- ledger so every receipt is a separate paid row and the remainder is derived
-- from invoice total minus net captured payments.

alter table public.rentals
  drop constraint if exists rentals_external_payment_method_check;
alter table public.rentals
  add constraint rentals_external_payment_method_check
  check (
    external_payment_method is null
    or external_payment_method in (
      'card', 'terminal', 'cash_app', 'cash', 'bank_transfer', 'other'
    )
  );
-- A rental-level payment amount can also be an unpaid Stripe quote. It becomes
-- captured money only when paid_at is present. Balance-ledger payments are
-- counted independently, preventing a quote from being counted twice after the
-- first installment changes payment_status to partially_paid.
create or replace function public.rentmect_rental_net_paid_amount(
  p_rental_id uuid
) returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_initial_paid numeric := 0;
  v_balance_paid numeric := 0;
  v_refunded numeric := 0;
begin
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then return 0; end if;

  if v_rental.paid_at is not null then
    v_initial_paid := greatest(0, coalesce(v_rental.payment_amount_cents, 0) / 100.0);
  end if;

  select coalesce(
    sum(coalesce(payment_amount_cents, round(total_amount * 100)::integer)) / 100.0,
    0
  ) into v_balance_paid
  from public.rental_charge_items
  where rental_id = p_rental_id
    and charge_type = 'rental_amendment'
    and status = 'paid';

  if to_regclass('public.rental_payment_refunds') is not null then
    execute $sql$
      select coalesce(sum(amount), 0)
      from public.rental_payment_refunds
      where rental_id = $1
        and extension_request_id is null
        and status in ('processing', 'pending', 'succeeded')
    $sql$ into v_refunded using p_rental_id;
  end if;

  return greatest(0, round(v_initial_paid + v_balance_paid - v_refunded, 2));
end;
$$;
revoke all on function public.rentmect_rental_net_paid_amount(uuid)
  from public, anon, authenticated;
grant execute on function public.rentmect_rental_net_paid_amount(uuid)
  to service_role;
create or replace function public.sync_rental_remaining_balance(
  p_rental_id uuid,
  p_actor_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_balance_charge public.rental_charge_items%rowtype;
  v_invoice numeric;
  v_paid numeric;
  v_due numeric;
  v_credit numeric;
  v_next_status text;
  v_final_provider text;
begin
  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;

  v_invoice := public.rentmect_rental_invoice_total(v_rental.id);
  v_paid := public.rentmect_rental_net_paid_amount(v_rental.id);
  v_due := greatest(0, round(v_invoice - v_paid, 2));
  v_credit := greatest(0, round(v_paid - v_invoice, 2));

  select * into v_balance_charge
  from public.rental_charge_items
  where rental_id = v_rental.id
    and charge_type = 'rental_amendment'
    and status in ('pending', 'checkout_open', 'failed')
  order by created_at desc, id desc
  limit 1
  for update;

  update public.rental_charge_items
  set status = 'waived',
      description = 'Superseded by the current remaining rental balance.',
      updated_at = now()
  where rental_id = v_rental.id
    and charge_type = 'rental_amendment'
    and status in ('pending', 'checkout_open', 'failed')
    and (v_balance_charge.id is null or id <> v_balance_charge.id);

  if v_due > 0.005 then
    if v_balance_charge.id is null then
      insert into public.rental_charge_items (
        rental_id, user_id, name, charge_type, description,
        amount, taxable, tax_amount, total_amount,
        included_in_initial_payment, status, created_by,
        source_type, source_reference
      ) values (
        v_rental.id, v_rental.user_id, 'Remaining rental balance',
        'rental_amendment',
        'Unpaid portion of the rental invoice after crediting payments already received.',
        v_due, false, 0, v_due, false, 'pending', p_actor_id,
        'rental_balance', gen_random_uuid()::text
      ) returning * into v_balance_charge;
    else
      update public.rental_charge_items
      set name = 'Remaining rental balance',
          description = 'Unpaid portion of the rental invoice after crediting payments already received.',
          amount = v_due,
          taxable = false,
          tax_amount = 0,
          total_amount = v_due,
          status = case when status = 'checkout_open' then 'checkout_open' else 'pending' end,
          payment_amount_cents = round(v_due * 100)::integer,
          last_admin_charge_error = null,
          updated_at = now()
      where id = v_balance_charge.id
      returning * into v_balance_charge;
    end if;
    v_next_status := case when v_paid > 0.005 then 'partially_paid' else 'pending' end;
  else
    if v_balance_charge.id is not null then
      update public.rental_charge_items
      set status = 'waived',
          description = 'No remaining rental balance after invoice reconciliation.',
          updated_at = now()
      where id = v_balance_charge.id;
      v_balance_charge.id := null;
    end if;
    v_next_status := case when v_paid > 0.005 then 'paid' else 'pending' end;
  end if;

  if v_next_status = 'paid' then
    select charge.payment_provider into v_final_provider
    from public.rental_charge_items charge
    where charge.rental_id = v_rental.id
      and charge.charge_type = 'rental_amendment'
      and charge.status = 'paid'
      and charge.payment_provider is not null
    order by charge.paid_at desc nulls last, charge.created_at desc
    limit 1;
    -- payment_provider may merely describe an abandoned Stripe quote. Trust it
    -- only when the rental-level payment was actually captured.
    v_final_provider := coalesce(
      case when v_rental.paid_at is not null
        then nullif(v_rental.payment_provider, '') end,
      v_final_provider,
      'local'
    );
  end if;

  update public.rentals
  set payment_status = v_next_status,
      payment_provider = case
        when v_next_status = 'paid' then v_final_provider
        else payment_provider
      end,
      deposit_status = case
        when v_next_status = 'paid' and coalesce(security_deposit, 0) <= 0 then 'waived'
        when v_next_status = 'paid'
          and lower(coalesce(deposit_status, 'pending')) in ('pending', 'not_due') then 'held'
        else deposit_status
      end,
      deposit_held_amount = case
        when v_next_status = 'paid' then greatest(
          coalesce(deposit_held_amount, 0), coalesce(security_deposit, 0)
        )
        else deposit_held_amount
      end,
      checkout_expires_at = case
        when v_next_status in ('paid', 'partially_paid') then null
        else checkout_expires_at
      end,
      payment_due_at = case
        when v_next_status in ('paid', 'partially_paid') then null
        else payment_due_at
      end,
      updated_at = now()
  where id = v_rental.id;

  if v_paid > 0.005
     and lower(coalesce(v_rental.status, 'pending')) in (
       'pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup'
     ) then
    update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and lower(coalesce(status, 'available')) = 'available';
  end if;

  if v_next_status = 'paid' then
    perform public.ensure_rental_deposit_allocation(v_rental.id);

    insert into public.rental_step_completions (
      rental_id, user_id, step_key, completion_source,
      note, metadata, completed_by
    ) values (
      v_rental.id, v_rental.user_id, 'payment',
      case when v_final_provider = 'stripe'
        then 'stripe_payment' else 'admin_external_payment' end,
      'Rental balance paid in full.',
      jsonb_build_object('net_paid', v_paid, 'payment_provider', v_final_provider),
      p_actor_id
    )
    on conflict (rental_id, step_key) do update set
      completion_source = excluded.completion_source,
      note = excluded.note,
      metadata = excluded.metadata,
      completed_by = excluded.completed_by,
      completed_at = now(),
      updated_at = now();

    insert into public.rental_step_completions (
      rental_id, user_id, step_key, completion_source,
      note, metadata, completed_by
    ) values (
      v_rental.id, v_rental.user_id, 'deposit',
      case when coalesce(v_rental.security_deposit, 0) > 0
        then 'admin_deposit_collected' else 'admin_waiver' end,
      case when coalesce(v_rental.security_deposit, 0) > 0
        then 'Deposit completed with the final rental balance payment.'
        else 'No security deposit was due.' end,
      jsonb_build_object('amount', coalesce(v_rental.security_deposit, 0)),
      p_actor_id
    )
    on conflict (rental_id, step_key) do update set
      completion_source = excluded.completion_source,
      note = excluded.note,
      metadata = excluded.metadata,
      completed_by = excluded.completed_by,
      completed_at = now(),
      updated_at = now();
  end if;

  return jsonb_build_object(
    'rental_id', v_rental.id,
    'invoice_total', v_invoice,
    'net_paid', v_paid,
    'balance_due', v_due,
    'credit_due', v_credit,
    'payment_status', v_next_status,
    'balance_charge_id', v_balance_charge.id
  );
end;
$$;
revoke all on function public.sync_rental_remaining_balance(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.sync_rental_remaining_balance(uuid,uuid)
  to service_role;
create or replace function public.record_admin_rental_balance_payment(
  p_rental_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_reference text default null,
  p_actor_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := coalesce(auth.uid(), p_actor_id);
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_balance_before numeric := 0;
  v_method text := lower(trim(coalesce(p_payment_method, '')));
  v_result jsonb;
begin
  if auth.role() <> 'service_role'
     and (v_admin_id is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;
  if auth.role() = 'service_role' and (
    v_admin_id is null or not exists (
      select 1 from public.profiles where id = v_admin_id and role = 'admin'
    )
  ) then
    raise exception 'A valid administrator actor is required.';
  end if;
  if v_amount <= 0 then raise exception 'Payment amount must be greater than $0.'; end if;
  if v_method not in ('card', 'terminal', 'cash_app', 'cash', 'bank_transfer', 'other') then
    raise exception 'Choose a valid external payment method.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot receive a payment.';
  end if;

  perform public.sync_rental_remaining_balance(p_rental_id, v_admin_id);
  select * into v_charge
  from public.rental_charge_items
  where rental_id = p_rental_id
    and charge_type = 'rental_amendment'
    and status in ('pending', 'checkout_open', 'failed')
  order by created_at desc, id desc
  limit 1
  for update;
  if not found then raise exception 'This rental has no remaining balance.'; end if;
  if v_amount > v_charge.total_amount + 0.005 then
    raise exception 'Payment exceeds the remaining rental balance of %.',
      to_char(v_charge.total_amount, 'FM$999,999,990.00');
  end if;
  v_balance_before := v_charge.total_amount;

  update public.rental_charge_items
  set amount = v_amount,
      total_amount = v_amount,
      status = 'paid',
      payment_provider = 'local',
      payment_amount_cents = round(v_amount * 100)::integer,
      payment_currency = 'usd',
      paid_at = now(),
      external_payment_method = v_method,
      external_payment_reference = nullif(trim(coalesce(p_reference, '')), ''),
      external_payment_recorded_by = v_admin_id,
      stripe_checkout_session_id = null,
      stripe_payment_intent_id = null,
      last_admin_charge_error = null,
      updated_at = now()
  where id = v_charge.id
  returning * into v_charge;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_charge.rental_id, v_charge.user_id, v_admin_id,
    'admin_rental_balance_payment_recorded',
    jsonb_build_object(
      'balance_payment_id', v_charge.id,
      'amount', v_amount,
      'payment_method', v_method,
      'reference', nullif(trim(coalesce(p_reference, '')), ''),
      'installment', v_amount < v_balance_before - 0.005,
      'balance_before', v_balance_before,
      'balance_after', greatest(0, round(v_balance_before - v_amount, 2))
    )
  );

  v_result := public.sync_rental_remaining_balance(p_rental_id, v_admin_id);
  return v_result || jsonb_build_object('payment', to_jsonb(v_charge));
end;
$$;
revoke all on function public.record_admin_rental_balance_payment(uuid,numeric,text,text,uuid)
  from public;
grant execute on function public.record_admin_rental_balance_payment(uuid,numeric,text,text,uuid)
  to authenticated, service_role;
-- A partial payment is captured money. It protects the reservation from the
-- unpaid-expiry sweep but never satisfies the payment or deposit release gate.
create or replace function public.initialize_rental_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_deadline_minutes integer := 60;
  v_payment_status text := lower(coalesce(new.payment_status, 'pending'));
begin
  if tg_op = 'INSERT' then
    if public.is_admin() and new.source_pending_booking_id is null then
      new.booking_source := 'admin_manual';
    elsif coalesce(new.booking_source, '') = '' then
      new.booking_source := 'customer_portal';
    end if;

    if v_payment_status not in ('paid', 'partially_paid', 'partial') then
      if new.booking_source = 'admin_manual' then
        select settings.admin_booking_payment_deadline_minutes
        into v_admin_deadline_minutes
        from public.booking_policy_settings settings where settings.id = true;
        v_admin_deadline_minutes := coalesce(v_admin_deadline_minutes, 60);
        new.payment_due_at := coalesce(
          new.payment_due_at,
          now() + make_interval(mins => v_admin_deadline_minutes)
        );
        new.checkout_expires_at := null;
      else
        new.checkout_expires_at := coalesce(new.checkout_expires_at, now() + interval '25 minutes');
        new.payment_due_at := coalesce(new.payment_due_at, new.checkout_expires_at);
      end if;
    end if;
  end if;

  if v_payment_status in ('paid', 'partially_paid', 'partial') then
    new.checkout_expires_at := null;
    new.payment_due_at := null;
  end if;
  if tg_op = 'UPDATE'
     and lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;
  return new;
end;
$$;
create or replace function public.prevent_cancelled_rental_payment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(coalesce(new.payment_status, '')) in ('paid', 'partially_paid', 'partial')
     and lower(coalesce(old.payment_status, '')) not in ('paid', 'partially_paid', 'partial')
     and lower(coalesce(old.status, '')) = 'cancelled' then
    raise exception 'Cancelled reservations cannot receive payments. Reconcile or refund the late payment.';
  end if;
  return new;
end;
$$;
create or replace function public.protect_partially_paid_rental_cancellation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled'
     and lower(coalesce(old.payment_status, '')) in ('partially_paid', 'partial') then
    raise exception 'Partially paid reservations require payment reconciliation before cancellation.';
  end if;
  return new;
end;
$$;
drop trigger if exists rentals_protect_partial_payment_cancellation on public.rentals;
create trigger rentals_protect_partial_payment_cancellation
before update of status on public.rentals
for each row execute function public.protect_partially_paid_rental_cancellation();
-- Keep the existing full external-payment API and behavior intact while
-- accepting every payment method already offered by the Admin UI.
create or replace function public.record_admin_local_rental_payment(
  p_rental_id uuid,
  p_amount numeric,
  p_payment_method text
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_amount_due numeric(12,2);
  v_amount_received numeric(12,2);
  v_payment_method text := lower(trim(coalesce(p_payment_method, '')));
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required to record an external payment.';
  end if;
  if v_payment_method not in ('card', 'terminal', 'cash_app', 'cash', 'bank_transfer', 'other') then
    raise exception 'Choose a valid external payment method.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Enter the actual external payment amount received.';
  end if;

  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be marked paid.';
  end if;
  if lower(coalesce(v_rental.payment_status, 'pending')) in ('paid', 'partially_paid', 'partial') then
    raise exception 'Use the remaining-balance payment action for this rental.';
  end if;

  v_amount_due := public.rentmect_rental_invoice_total(v_rental.id);
  v_amount_received := round(p_amount, 2);
  if abs(v_amount_received - v_amount_due) > 0.005 then
    raise exception 'The full-payment action must equal the amount due: %.',
      to_char(v_amount_due, 'FM$999,999,990.00');
  end if;

  update public.rentals
  set payment_status = 'paid',
      deposit_status = case when coalesce(security_deposit, 0) > 0 then 'held' else 'waived' end,
      payment_provider = 'local',
      payment_amount_cents = round(v_amount_received * 100)::integer,
      paid_at = coalesce(paid_at, now()),
      external_payment_amount = v_amount_received,
      external_payment_method = v_payment_method,
      external_payment_recorded_at = now(),
      external_payment_recorded_by = v_admin_id,
      deposit_held_amount = greatest(
        coalesce(deposit_held_amount, 0), coalesce(security_deposit, 0)
      ),
      updated_at = now()
  where id = p_rental_id
  returning * into v_rental;

  update public.rental_charge_items
  set status = 'paid', payment_provider = 'local',
      paid_at = coalesce(paid_at, now()), updated_at = now()
  where rental_id = v_rental.id
    and included_in_initial_payment
    and status <> 'paid';

  perform public.ensure_rental_deposit_allocation(v_rental.id);

  insert into public.rental_step_completions (
    rental_id, user_id, step_key, completion_source, note, metadata, completed_by
  ) values (
    v_rental.id, v_rental.user_id, 'payment', 'admin_external_payment',
    'Payment collected and recorded by admin.',
    jsonb_build_object('amount', v_amount_received, 'payment_method', v_payment_method),
    v_admin_id
  ) on conflict (rental_id, step_key) do update set
    completion_source = excluded.completion_source,
    note = excluded.note,
    metadata = excluded.metadata,
    completed_by = excluded.completed_by,
    completed_at = now(), updated_at = now();

  insert into public.rental_step_completions (
    rental_id, user_id, step_key, completion_source, note, metadata, completed_by
  ) values (
    v_rental.id, v_rental.user_id, 'deposit',
    case when coalesce(v_rental.security_deposit, 0) > 0
      then 'admin_deposit_collected' else 'admin_waiver' end,
    case when coalesce(v_rental.security_deposit, 0) > 0
      then 'Deposit included in external payment.' else 'No deposit was due.' end,
    jsonb_build_object('amount', coalesce(v_rental.security_deposit, 0)),
    v_admin_id
  ) on conflict (rental_id, step_key) do update set
    completion_source = excluded.completion_source,
    note = excluded.note,
    metadata = excluded.metadata,
    completed_by = excluded.completed_by,
    completed_at = now(), updated_at = now();

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_local_payment_recorded',
    jsonb_build_object(
      'source', 'record_admin_local_rental_payment',
      'amount', v_amount_received,
      'payment_method', v_payment_method,
      'assisted_booking', true
    )
  );

  update public.vehicles
  set status = 'reserved'
  where id = v_rental.vehicle_id
    and lower(coalesce(status, 'available')) not in ('maintenance', 'unavailable', 'inactive');

  v_rental := public.sync_rental_ready_for_pickup_global(v_rental.id);
  return v_rental;
end;
$$;
revoke all on function public.record_admin_local_rental_payment(uuid,numeric,text)
  from public;
grant execute on function public.record_admin_local_rental_payment(uuid,numeric,text)
  to authenticated;
notify pgrst, 'reload schema';
commit;
