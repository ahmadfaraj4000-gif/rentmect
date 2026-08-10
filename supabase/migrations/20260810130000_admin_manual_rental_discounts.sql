-- Reservation-specific administrator discounts.
-- These adjustments change only the selected rental's stored invoice. They do
-- not touch vehicle rates, public pricing, discount-code inventory, deposits,
-- additional charges, or captured payment history.

alter table public.rentals
  add column if not exists manual_discount_amount numeric(10,2) not null default 0
    check (manual_discount_amount >= 0),
  add column if not exists manual_discount_tax_savings numeric(10,2) not null default 0
    check (manual_discount_tax_savings >= 0),
  add column if not exists manual_discount_type text
    check (manual_discount_type in ('fixed', 'percentage')),
  add column if not exists manual_discount_value numeric(10,2)
    check (manual_discount_value >= 0),
  add column if not exists pre_manual_discount_rental_total numeric(10,2),
  add column if not exists pre_manual_discount_tax_amount numeric(10,2),
  add column if not exists manual_discount_reason text,
  add column if not exists manual_discount_applied_by uuid references auth.users(id) on delete set null,
  add column if not exists manual_discount_applied_at timestamptz;

comment on column public.rentals.manual_discount_amount is
  'Admin-entered rental-subtotal reduction for this reservation only. Promotional discount fields remain independent.';
comment on column public.rentals.manual_discount_tax_savings is
  'CT sales-tax reduction caused by the reservation-specific manual discount.';
comment on column public.rentals.pre_manual_discount_rental_total is
  'Rental subtotal, after any promotion, immediately before the manual discount.';

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
  v_non_taxable_fees numeric;
  v_deposit numeric;
  v_old_total numeric;
  v_base_total numeric;
  v_new_total numeric;
  v_minimum_total numeric;
  v_requested_savings numeric;
  v_requested_target numeric;
  v_iteration integer := 0;
begin
  if auth.role() <> 'service_role'
     and (auth.uid() is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be discounted.';
  end if;

  if v_mode not in ('fixed', 'percentage', 'remove') then
    raise exception 'Choose a dollar discount, percentage discount, or remove.';
  end if;

  v_service_fees := round(coalesce(v_rental.service_fee_total, 0), 2);
  v_taxable_fees := round(coalesce(v_rental.taxable_service_fee_total, 0), 2);
  v_non_taxable_fees := round(v_service_fees - v_taxable_fees, 2);
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

  v_old_total := round(
    coalesce(v_rental.rental_total, 0) + v_service_fees
      + coalesce(v_rental.tax_amount, 0) + v_deposit, 2
  );
  v_base_total := round(v_base_rental + v_service_fees + v_base_tax + v_deposit, 2);
  v_minimum_total := round(
    v_non_taxable_fees + v_taxable_fees
      + round(v_taxable_fees * 0.0635, 2) + v_deposit, 2
  );
  if v_mode = 'remove' then
    v_new_rental := v_base_rental;
  else
    if v_mode = 'fixed' and v_value <= 0 then
      raise exception 'Discount amount must be greater than $0.';
    end if;
    if v_mode = 'percentage' and (v_value <= 0 or v_value > 100) then
      raise exception 'Percentage discount must be greater than 0 and no more than 100.';
    end if;

    v_requested_savings := case
      when v_mode = 'percentage' then round(v_base_total * v_value / 100, 2)
      else v_value
    end;
    if v_requested_savings > round(v_base_total - v_minimum_total, 2) then
      raise exception 'The largest available discount is % because the refundable deposit and separate fees stay unchanged.',
        to_char(round(v_base_total - v_minimum_total, 2), 'FM$999,999,990.00');
    end if;
    v_requested_target := round(v_base_total - v_requested_savings, 2);

    -- Find the pre-tax rental reduction that makes the final invoice fall by
    -- exactly the entered dollars or percentage after CT tax rounding.
    v_new_rental := round(
      ((v_requested_target - v_deposit - v_non_taxable_fees) / 1.0635)
        - v_taxable_fees,
      2
    );
    v_new_rental := greatest(0, least(v_base_rental, v_new_rental));
    loop
      v_new_tax := round((v_new_rental + v_taxable_fees) * 0.0635, 2);
      v_new_total := round(v_new_rental + v_service_fees + v_new_tax + v_deposit, 2);
      exit when abs(v_new_total - v_requested_target) < 0.005;
      exit when v_iteration >= 200;
      if v_new_total > v_requested_target then
        v_new_rental := greatest(0, v_new_rental - 0.01);
      else
        v_new_rental := least(v_base_rental, v_new_rental + 0.01);
      end if;
      v_iteration := v_iteration + 1;
    end loop;
    if abs(v_new_total - v_requested_target) >= 0.005 then
      raise exception 'That exact discount is not possible after CT tax rounding. Try one cent higher or lower.';
    end if;
  end if;

  v_new_tax := round((v_new_rental + v_taxable_fees) * 0.0635, 2);
  v_new_total := round(v_new_rental + v_service_fees + v_new_tax + v_deposit, 2);
  v_discount := round(v_base_rental - v_new_rental, 2);
  v_tax_savings := greatest(0, round(v_base_tax - v_new_tax, 2));

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
    'paid_credit_due', case
      when lower(coalesce(v_rental.payment_status, 'pending')) = 'paid'
        and v_new_total < v_old_total
      then round(v_old_total - v_new_total, 2)
      else 0
    end
  );
end;
$$;

revoke all on function public.admin_preview_manual_rental_discount(uuid,text,numeric) from public;
grant execute on function public.admin_preview_manual_rental_discount(uuid,text,numeric)
  to authenticated, service_role;

create or replace function public.admin_apply_manual_rental_discount(
  p_rental_id uuid,
  p_mode text,
  p_value numeric,
  p_reason text,
  p_idempotency_key uuid,
  p_actor_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := coalesce(auth.uid(), p_actor_id);
  v_rental public.rentals%rowtype;
  v_updated public.rentals%rowtype;
  v_existing public.rental_amendments%rowtype;
  v_amendment public.rental_amendments%rowtype;
  v_preview jsonb;
  v_old_total numeric;
  v_new_total numeric;
  v_total_delta numeric;
  v_settlement_status text;
  v_requires_resign boolean;
begin
  if auth.role() <> 'service_role'
     and (v_actor_id is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;
  if auth.role() = 'service_role' and p_actor_id is not null
     and not exists (select 1 from public.profiles where id = p_actor_id and role = 'admin') then
    raise exception 'A valid administrator actor is required.';
  end if;
  if p_idempotency_key is null then raise exception 'Idempotency key is required.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Enter a specific reason of at least 10 characters.';
  end if;

  select * into v_existing
  from public.rental_amendments
  where idempotency_key = p_idempotency_key;
  if found then
    select * into v_updated from public.rentals where id = v_existing.rental_id;
    return jsonb_build_object(
      'amendment', to_jsonb(v_existing),
      'rental', to_jsonb(v_updated),
      'idempotent_replay', true
    );
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;

  v_preview := public.admin_preview_manual_rental_discount(p_rental_id, p_mode, p_value);
  v_old_total := round((v_preview ->> 'old_total')::numeric, 2);
  v_new_total := round((v_preview ->> 'new_total')::numeric, 2);
  v_total_delta := round(v_new_total - v_old_total, 2);
  v_settlement_status := case
    when lower(coalesce(v_rental.payment_status, 'pending')) <> 'paid'
      then 'unpaid_repriced'
    when v_total_delta < -0.005 then 'customer_credit_due'
    when v_total_delta > 0.005 then 'customer_charge_pending'
    else 'no_change'
  end;
  if v_settlement_status = 'customer_charge_pending' then
    raise exception 'A paid rental discount cannot be reduced or removed until its customer credit is settled.';
  end if;
  v_requires_resign := coalesce(v_rental.agreement_signed, false)
    and lower(coalesce(v_rental.status, '')) <> 'completed'
    and abs(v_total_delta) > 0.005;

  insert into public.rental_amendments (
    idempotency_key, rental_id, actor_id, reason, rental_state,
    old_values, new_values, pricing_delta, deposit_delta, total_delta,
    settlement_status, credit_amount, requires_customer_resign
  ) values (
    p_idempotency_key, v_rental.id, v_actor_id, trim(p_reason),
    coalesce(v_rental.status, 'unknown'),
    jsonb_build_object(
      'rental_total', v_rental.rental_total,
      'tax_amount', v_rental.tax_amount,
      'service_fee_total', v_rental.service_fee_total,
      'security_deposit', v_rental.security_deposit,
      'manual_discount_amount', v_rental.manual_discount_amount,
      'manual_discount_tax_savings', v_rental.manual_discount_tax_savings,
      'manual_discount_type', v_rental.manual_discount_type,
      'manual_discount_value', v_rental.manual_discount_value,
      'total', v_old_total
    ),
    jsonb_build_object(
      'rental_total', (v_preview ->> 'rental_total')::numeric,
      'tax_amount', (v_preview ->> 'tax_amount')::numeric,
      'service_fee_total', v_rental.service_fee_total,
      'security_deposit', v_rental.security_deposit,
      'manual_discount_amount', (v_preview ->> 'manual_discount_amount')::numeric,
      'manual_discount_tax_savings', (v_preview ->> 'manual_discount_tax_savings')::numeric,
      'manual_discount_type', v_preview ->> 'manual_discount_type',
      'manual_discount_value', (v_preview ->> 'manual_discount_value')::numeric,
      'total', v_new_total
    ),
    round(v_total_delta, 2), 0, v_total_delta, v_settlement_status,
    case when v_settlement_status = 'customer_credit_due' then abs(v_total_delta) else 0 end,
    v_requires_resign
  ) returning * into v_amendment;

  update public.rentals
  set pre_manual_discount_rental_total = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0
          then (v_preview ->> 'pre_manual_discount_rental_total')::numeric
        else null
      end,
      pre_manual_discount_tax_amount = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0
          then (v_preview ->> 'pre_manual_discount_tax_amount')::numeric
        else null
      end,
      manual_discount_amount = (v_preview ->> 'manual_discount_amount')::numeric,
      manual_discount_tax_savings = (v_preview ->> 'manual_discount_tax_savings')::numeric,
      manual_discount_type = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0
          then v_preview ->> 'manual_discount_type'
        else null
      end,
      manual_discount_value = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0
          then (v_preview ->> 'manual_discount_value')::numeric
        else null
      end,
      manual_discount_reason = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0 then trim(p_reason)
        else null
      end,
      manual_discount_applied_by = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0 then v_actor_id
        else null
      end,
      manual_discount_applied_at = case
        when (v_preview ->> 'manual_discount_amount')::numeric > 0 then now()
        else null
      end,
      rental_total = (v_preview ->> 'rental_total')::numeric,
      tax_amount = (v_preview ->> 'tax_amount')::numeric,
      payment_amount_cents = case
        when lower(coalesce(payment_status, 'pending')) <> 'paid'
          then round(v_new_total * 100)::integer
        else payment_amount_cents
      end,
      agreement_signed = case when v_requires_resign then false else agreement_signed end,
      agreement_version = case when v_requires_resign then null else agreement_version end,
      agreement_snapshot = case when v_requires_resign then null else agreement_snapshot end,
      agreement_hash = case when v_requires_resign then null else agreement_hash end,
      agreement_signed_at = case when v_requires_resign then null else agreement_signed_at end,
      agreement_signature_name = case when v_requires_resign then null else agreement_signature_name end,
      agreement_ip = case when v_requires_resign then null else agreement_ip end,
      agreement_user_agent = case when v_requires_resign then null else agreement_user_agent end,
      status = case
        when v_requires_resign and lower(coalesce(status, '')) in ('approved', 'ready_for_pickup')
          then 'document_review'
        else status
      end,
      updated_at = now()
  where id = v_rental.id
  returning * into v_updated;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_updated.id, v_updated.user_id, v_actor_id,
    case when coalesce(v_updated.manual_discount_amount, 0) > 0
      then 'admin_manual_discount_applied'
      else 'admin_manual_discount_removed'
    end,
    jsonb_build_object(
      'amendment_id', v_amendment.id,
      'reason', trim(p_reason),
      'mode', lower(trim(p_mode)),
      'old_total', v_old_total,
      'new_total', v_new_total,
      'manual_discount_amount', v_updated.manual_discount_amount,
      'tax_savings', v_updated.manual_discount_tax_savings,
      'discount_type', v_updated.manual_discount_type,
      'discount_value', v_updated.manual_discount_value,
      'settlement_status', v_settlement_status,
      'requires_customer_resign', v_requires_resign
    )
  );

  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  )
  select
    'manual_rental_discount:' || v_amendment.id::text,
    'rental_amendment_notice', templates.id, v_updated.id, v_updated.user_id,
    lower(trim(profiles.email)), profiles.full_name,
    jsonb_build_object(
      'customer_name', coalesce(profiles.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(profiles.full_name, 'Customer'), ' ', 1),
      'vehicle_name', coalesce(vehicles.name, 'Your rental vehicle'),
      'pickup_date', coalesce(to_char(v_updated.pickup_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
      'pickup_time', coalesce(v_updated.pickup_time, 'To be confirmed'),
      'return_date', coalesce(to_char(v_updated.return_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
      'return_time', coalesce(v_updated.return_time, 'To be confirmed'),
      'updated_total', to_char(v_new_total, 'FM$999,999,990.00'),
      'payment_update', case v_settlement_status
        when 'customer_credit_due' then 'A customer credit of '
          || to_char(abs(v_total_delta), 'FM$999,999,990.00')
          || ' is recorded for administrator review.'
        else 'Your unpaid checkout total has been updated.'
      end,
      'agreement_update', case when v_requires_resign
        then 'Please review and sign the updated rental agreement before pickup.'
        else 'Your signed agreement status did not change.'
      end,
      'manage_booking_url', 'https://login.rentmect.com'
    )
  from public.profiles profiles
  join public.email_templates templates
    on templates.template_key = 'rental_amendment_notice' and templates.enabled
  left join public.vehicles vehicles on vehicles.id = v_updated.vehicle_id
  where profiles.id = v_updated.user_id
    and nullif(trim(coalesce(profiles.email, '')), '') is not null
  on conflict (event_key) do nothing;

  return jsonb_build_object(
    'amendment', to_jsonb(v_amendment),
    'rental', to_jsonb(v_updated),
    'preview', v_preview,
    'checkout_session_id', v_rental.stripe_checkout_session_id,
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.admin_apply_manual_rental_discount(uuid,text,numeric,text,uuid,uuid) from public;
grant execute on function public.admin_apply_manual_rental_discount(uuid,text,numeric,text,uuid,uuid)
  to authenticated, service_role;

-- Preserve the fixed reservation discount when a later guarded admin edit
-- changes the vehicle, dates, or daily rate. The existing amendment function
-- calls the public preview function, so this wrapper also keeps its audit and
-- settlement deltas accurate.
alter function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) rename to admin_preview_rental_amendment_without_manual_discount;

revoke all on function public.admin_preview_rental_amendment_without_manual_discount(
  uuid, uuid, date, text, date, text, numeric, numeric
) from public;
grant execute on function public.admin_preview_rental_amendment_without_manual_discount(
  uuid, uuid, date, text, date, text, numeric, numeric
) to service_role;

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
begin
  v_preview := public.admin_preview_rental_amendment_without_manual_discount(
    p_rental_id, p_vehicle_id, p_pickup_date, p_pickup_time,
    p_return_date, p_return_time, p_daily_rate, p_security_deposit
  );

  select * into v_rental from public.rentals where id = p_rental_id;
  v_manual_discount := least(
    round(coalesce(v_rental.manual_discount_amount, 0), 2),
    round(coalesce((v_preview #>> '{new,rental_total}')::numeric, 0), 2)
  );
  if v_manual_discount <= 0 then return v_preview; end if;

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
  return v_preview;
end;
$$;

revoke all on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) from public;
grant execute on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) to authenticated, service_role;
