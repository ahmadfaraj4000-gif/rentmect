-- Keep post-payment rental edits inside the rental payment lifecycle.
-- A revised invoice is settled against money already received. Any remainder
-- becomes one system-managed rental balance; it is not a toll or manual fee.

alter table public.rental_charge_items
  add column if not exists external_payment_method text,
  add column if not exists external_payment_reference text,
  add column if not exists external_payment_recorded_by uuid
    references auth.users(id) on delete set null;

create or replace function public.rentmect_rental_invoice_total(
  p_rental_id uuid
) returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select round(
    coalesce(rental_total, 0)
      + coalesce(service_fee_total, 0)
      + coalesce(tax_amount, 0)
      + coalesce(security_deposit, 0),
    2
  )
  from public.rentals
  where id = p_rental_id;
$$;

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

  -- payment_amount_cents is also used as an unpaid Checkout quote. Count it
  -- only after the original rental payment was actually captured.
  if v_rental.paid_at is not null
     or lower(coalesce(v_rental.payment_status, '')) in (
       'paid', 'partially_paid', 'partial'
     ) then
    v_initial_paid := greatest(0, coalesce(v_rental.payment_amount_cents, 0) / 100.0);
  end if;

  select coalesce(sum(coalesce(payment_amount_cents, round(total_amount * 100)::integer)) / 100.0, 0)
    into v_balance_paid
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

revoke all on function public.rentmect_rental_invoice_total(uuid)
  from public, anon, authenticated;
revoke all on function public.rentmect_rental_net_paid_amount(uuid)
  from public, anon, authenticated;
grant execute on function public.rentmect_rental_invoice_total(uuid)
  to service_role;
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
        'Unpaid portion of the revised rental invoice after crediting payments already received.',
        v_due, false, 0, v_due, false, 'pending', p_actor_id,
        'rental_balance', gen_random_uuid()::text
      ) returning * into v_balance_charge;
    else
      update public.rental_charge_items
      set name = 'Remaining rental balance',
          description = 'Unpaid portion of the revised rental invoice after crediting payments already received.',
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

  update public.rentals
  set payment_status = v_next_status,
      updated_at = now()
  where id = v_rental.id
    and payment_status is distinct from v_next_status;

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

create or replace function public.protect_captured_rental_payment_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.paid_at is not null
     or lower(coalesce(old.payment_status, '')) in (
       'paid', 'partially_paid', 'partial'
     ) then
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
  stripe_customer_id, payment_provider, paid_at
on public.rentals
for each row execute function public.protect_captured_rental_payment_snapshot();

create or replace function public.sync_balance_after_rental_invoice_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(old.payment_status, '')) in ('paid', 'partially_paid', 'partial')
     or old.paid_at is not null
     or exists (
       select 1 from public.rental_charge_items
       where rental_id = new.id and charge_type = 'rental_amendment'
     ) then
    perform public.sync_rental_remaining_balance(new.id, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_sync_remaining_balance on public.rentals;
create trigger rentals_sync_remaining_balance
after update of rental_total, service_fee_total, tax_amount, security_deposit
on public.rentals
for each row
when (
  old.rental_total is distinct from new.rental_total
  or old.service_fee_total is distinct from new.service_fee_total
  or old.tax_amount is distinct from new.tax_amount
  or old.security_deposit is distinct from new.security_deposit
)
execute function public.sync_balance_after_rental_invoice_change();

create or replace function public.sync_balance_after_charge_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.charge_type = 'rental_amendment'
     and new.status = 'paid'
     and old.status is distinct from new.status then
    perform public.sync_rental_remaining_balance(new.rental_id, new.external_payment_recorded_by);
  end if;
  return new;
end;
$$;

drop trigger if exists rental_balance_payment_sync on public.rental_charge_items;
create trigger rental_balance_payment_sync
after update of status on public.rental_charge_items
for each row execute function public.sync_balance_after_charge_payment();

create or replace function public.sync_balance_after_balance_charge_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.charge_type = 'rental_amendment' and pg_trigger_depth() = 1 then
    perform public.sync_rental_remaining_balance(new.rental_id, new.created_by);
  end if;
  return new;
end;
$$;

drop trigger if exists rental_balance_insert_sync on public.rental_charge_items;
create trigger rental_balance_insert_sync
after insert on public.rental_charge_items
for each row execute function public.sync_balance_after_balance_charge_insert();

-- A fixed amount is an exact rental-subtotal reduction. Tax savings are
-- additional and are shown separately. Percentage discounts use the same
-- rental-only base, never the refundable deposit.
create or replace function public.admin_preview_manual_rental_discount(
  p_rental_id uuid,
  p_mode text,
  p_value numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_mode text := lower(trim(coalesce(p_mode, '')));
  v_value numeric := round(coalesce(p_value, 0), 2);
  v_base_rental numeric;
  v_base_tax numeric;
  v_new_rental numeric;
  v_new_tax numeric;
  v_discount numeric;
  v_tax_savings numeric;
  v_service_fees numeric;
  v_taxable_fees numeric;
  v_deposit numeric;
  v_old_total numeric;
  v_base_total numeric;
  v_new_total numeric;
  v_paid numeric;
begin
  if auth.role() <> 'service_role'
     and (auth.uid() is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;

  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be discounted.';
  end if;
  if v_mode not in ('fixed', 'percentage', 'remove') then
    raise exception 'Choose a dollar discount, percentage discount, or remove.';
  end if;

  v_service_fees := round(coalesce(v_rental.service_fee_total, 0), 2);
  v_taxable_fees := round(coalesce(v_rental.taxable_service_fee_total, 0), 2);
  v_deposit := round(coalesce(v_rental.security_deposit, 0), 2);
  v_base_rental := round(case
    when coalesce(v_rental.manual_discount_amount, 0) > 0
      then coalesce(v_rental.pre_manual_discount_rental_total,
        v_rental.rental_total + v_rental.manual_discount_amount)
    else coalesce(v_rental.rental_total, 0)
  end, 2);
  v_base_tax := round(case
    when coalesce(v_rental.manual_discount_amount, 0) > 0
      then coalesce(v_rental.pre_manual_discount_tax_amount,
        (v_base_rental + v_taxable_fees) * 0.0635)
    else coalesce(v_rental.tax_amount,
      round((v_base_rental + v_taxable_fees) * 0.0635, 2))
  end, 2);

  if v_mode = 'remove' then
    v_discount := 0;
  else
    if v_mode = 'fixed' and v_value <= 0 then
      raise exception 'Discount amount must be greater than $0.';
    end if;
    if v_mode = 'percentage' and (v_value <= 0 or v_value > 100) then
      raise exception 'Percentage discount must be greater than 0 and no more than 100.';
    end if;
    v_discount := case
      when v_mode = 'percentage' then round(v_base_rental * v_value / 100, 2)
      else v_value
    end;
    if v_discount > v_base_rental then
      raise exception 'The rental discount cannot exceed %.',
        to_char(v_base_rental, 'FM$999,999,990.00');
    end if;
  end if;

  v_new_rental := round(v_base_rental - v_discount, 2);
  v_new_tax := round((v_new_rental + v_taxable_fees) * 0.0635, 2);
  v_tax_savings := greatest(0, round(v_base_tax - v_new_tax, 2));
  v_old_total := round(
    coalesce(v_rental.rental_total, 0) + v_service_fees
      + coalesce(v_rental.tax_amount, 0) + v_deposit, 2
  );
  v_base_total := round(v_base_rental + v_service_fees + v_base_tax + v_deposit, 2);
  v_new_total := round(v_new_rental + v_service_fees + v_new_tax + v_deposit, 2);
  v_paid := public.rentmect_rental_net_paid_amount(v_rental.id);

  return jsonb_build_object(
    'rental_id', v_rental.id,
    'mode', v_mode,
    'payment_status', coalesce(v_rental.payment_status, 'pending'),
    'old_total', v_old_total,
    'base_total', v_base_total,
    'new_total', v_new_total,
    'total_savings', round(v_base_total - v_new_total, 2),
    'manual_discount_amount', v_discount,
    'manual_discount_tax_savings', v_tax_savings,
    'manual_discount_type', case when v_mode = 'remove' then null else v_mode end,
    'manual_discount_value', case when v_mode = 'remove' then null else v_value end,
    'pre_manual_discount_rental_total', v_base_rental,
    'pre_manual_discount_tax_amount', v_base_tax,
    'rental_total', v_new_rental,
    'tax_amount', v_new_tax,
    'service_fee_total', v_service_fees,
    'security_deposit', v_deposit,
    'deposit_unchanged', true,
    'net_paid', v_paid,
    'balance_due', greatest(0, round(v_new_total - v_paid, 2)),
    'paid_credit_due', greatest(0, round(v_paid - v_new_total, 2))
  );
end;
$$;

revoke all on function public.admin_preview_manual_rental_discount(uuid,text,numeric) from public;
grant execute on function public.admin_preview_manual_rental_discount(uuid,text,numeric)
  to authenticated, service_role;

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
  v_charge public.rental_charge_items%rowtype;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
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
  if nullif(trim(coalesce(p_payment_method, '')), '') is null then
    raise exception 'Choose the external payment method.';
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

  update public.rental_charge_items
  set amount = v_amount,
      total_amount = v_amount,
      status = 'paid',
      payment_provider = 'local',
      payment_amount_cents = round(v_amount * 100)::integer,
      payment_currency = 'usd',
      paid_at = now(),
      external_payment_method = lower(trim(p_payment_method)),
      external_payment_reference = nullif(trim(coalesce(p_reference, '')), ''),
      external_payment_recorded_by = v_admin_id,
      stripe_checkout_session_id = null,
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
      'payment_method', lower(trim(p_payment_method)),
      'reference', nullif(trim(coalesce(p_reference, '')), '')
    )
  );

  v_result := public.sync_rental_remaining_balance(p_rental_id, v_admin_id);
  return v_result || jsonb_build_object('payment', to_jsonb(v_charge));
end;
$$;

revoke all on function public.record_admin_rental_balance_payment(uuid,numeric,text,text,uuid) from public;
grant execute on function public.record_admin_rental_balance_payment(uuid,numeric,text,text,uuid)
  to authenticated, service_role;

-- Rental balances have their own amendment notice and payment receipt. Do not
-- also send the generic toll/additional-charge messages.
create or replace function public.queue_additional_charge_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype;
begin
  if new.included_in_initial_payment or new.charge_type = 'rental_amendment' then return new; end if;
  select * into v_template from public.email_templates where template_key = 'additional_charge_due' and enabled limit 1;
  if not found then return new; end if;
  select * into v_profile from public.profiles where id = new.user_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;
  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'additional_charge_due:' || new.id::text, 'additional_charge_due',
    v_template.id, new.rental_id, new.user_id, lower(trim(v_profile.email)),
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

create or replace function public.queue_additional_charge_paid_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype;
begin
  if new.included_in_initial_payment or new.charge_type = 'rental_amendment'
     or new.status <> 'paid' or old.status is not distinct from new.status then return new; end if;
  select * into v_template from public.email_templates where template_key = 'additional_charge_paid' and enabled limit 1;
  if not found then return new; end if;
  select * into v_profile from public.profiles where id = new.user_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;
  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'additional_charge_paid:' || new.id::text, 'additional_charge_paid',
    v_template.id, new.rental_id, new.user_id, lower(trim(v_profile.email)),
    v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'charge_name', new.name,
      'charge_total', to_char(new.total_amount, 'FM$999,999,990.00'),
      'manage_booking_url', 'https://login.rentmect.com/?billing=1'
    )
  ) on conflict (event_key) do nothing;
  return new;
end;
$$;

-- Correct fixed discounts created by the previous tax-inclusive algorithm.
update public.rentals
set manual_discount_amount = least(
      round(manual_discount_value, 2),
      round(pre_manual_discount_rental_total, 2)
    ),
    rental_total = round(
      pre_manual_discount_rental_total
        - least(round(manual_discount_value, 2), round(pre_manual_discount_rental_total, 2)),
      2
    ),
    tax_amount = round((
      pre_manual_discount_rental_total
        - least(round(manual_discount_value, 2), round(pre_manual_discount_rental_total, 2))
        + coalesce(taxable_service_fee_total, 0)
    ) * 0.0635, 2),
    manual_discount_tax_savings = greatest(0, round(
      pre_manual_discount_tax_amount - round((
        pre_manual_discount_rental_total
          - least(round(manual_discount_value, 2), round(pre_manual_discount_rental_total, 2))
          + coalesce(taxable_service_fee_total, 0)
      ) * 0.0635, 2),
      2
    )),
    updated_at = now()
where manual_discount_type = 'fixed'
  and coalesce(manual_discount_value, 0) > 0
  and pre_manual_discount_rental_total is not null
  and pre_manual_discount_tax_amount is not null
  and abs(coalesce(manual_discount_amount, 0) - manual_discount_value) > 0.005;

-- Reconcile legacy amendment charges, including the affected production
-- rental, from the invoice and captured-payment facts instead of old deltas.
do $$
declare v_rental_id uuid;
begin
  for v_rental_id in
    select distinct rental_id
    from public.rental_charge_items
    where charge_type = 'rental_amendment'
  loop
    perform public.sync_rental_remaining_balance(v_rental_id, null);
  end loop;
end
$$;
