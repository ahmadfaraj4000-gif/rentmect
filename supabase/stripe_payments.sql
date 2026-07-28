-- Stripe Checkout payment tracking and webhook-safe payment recording.
-- Apply this after the rental workflow and extension SQL files.

create table if not exists public.stripe_webhook_events (
  id text primary key,
  event_type text not null,
  target_type text,
  rental_id uuid references public.rentals(id) on delete set null,
  extension_request_id uuid references public.rental_extension_requests(id) on delete set null,
  processed_at timestamptz not null default now(),
  payload jsonb
);

alter table public.rentals
  add column if not exists payment_provider text,
  add column if not exists stripe_checkout_session_id text,
  add column if not exists stripe_payment_intent_id text,
  add column if not exists stripe_customer_id text,
  add column if not exists payment_amount_cents integer,
  add column if not exists payment_currency text default 'usd';

alter table public.rental_extension_requests
  add column if not exists payment_provider text,
  add column if not exists stripe_checkout_session_id text,
  add column if not exists stripe_payment_intent_id text,
  add column if not exists stripe_customer_id text,
  add column if not exists payment_amount_cents integer,
  add column if not exists payment_currency text default 'usd';

create index if not exists rentals_stripe_checkout_session_id_idx
  on public.rentals (stripe_checkout_session_id);

create index if not exists rental_extension_requests_stripe_checkout_session_id_idx
  on public.rental_extension_requests (stripe_checkout_session_id);

create or replace function public.record_stripe_checkout_payment(
  p_event_id text,
  p_event_type text,
  p_target_type text,
  p_target_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_customer_id text,
  p_amount_total integer,
  p_currency text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_request public.rental_extension_requests%rowtype;
  v_parent_rental public.rentals%rowtype;
  v_replacement public.vehicles%rowtype;
  v_new_rental public.rentals%rowtype;
  v_expected_amount integer;
begin
  if coalesce(p_event_id, '') = '' then
    raise exception 'Stripe event id is required.';
  end if;

  insert into public.stripe_webhook_events (
    id, event_type, target_type, rental_id, extension_request_id, payload
  )
  values (
    p_event_id,
    coalesce(p_event_type, 'checkout.session.completed'),
    p_target_type,
    case when p_target_type = 'rental' then p_target_id else null end,
    case when p_target_type = 'extension' then p_target_id else null end,
    coalesce(p_payload, '{}'::jsonb)
  )
  on conflict (id) do nothing;

  if not found then
    return jsonb_build_object('processed', false, 'reason', 'duplicate_event');
  end if;

  if lower(coalesce(p_currency, 'usd')) <> 'usd' then
    raise exception 'Unexpected Stripe currency.';
  end if;

  if p_target_type = 'rental' then
    select *
      into v_rental
      from public.rentals
      where id = p_target_id
      for update;

    if not found then
      raise exception 'Rental not found for Stripe checkout.';
    end if;

    if coalesce(v_rental.stripe_checkout_session_id, p_checkout_session_id) <> p_checkout_session_id then
      raise exception 'Stripe checkout session does not match this rental.';
    end if;

    v_expected_amount := round((
      coalesce(v_rental.rental_total, 0) +
      coalesce(v_rental.service_fee_total, 0) +
      coalesce(v_rental.tax_amount, 0) +
      coalesce(v_rental.security_deposit, 0)
    ) * 100)::integer;

    if p_amount_total <> v_expected_amount then
      raise exception 'Stripe payment amount does not match the rental total.';
    end if;

    update public.rentals
      set payment_status = 'paid',
          deposit_status = 'held',
          paid_at = coalesce(paid_at, now()),
          deposit_held_amount = greatest(
            coalesce(deposit_held_amount, 0),
            coalesce(security_deposit, 0)
          ),
          payment_provider = 'stripe',
          stripe_checkout_session_id = p_checkout_session_id,
          stripe_payment_intent_id = p_payment_intent_id,
          stripe_customer_id = p_customer_id,
          payment_amount_cents = p_amount_total,
          payment_currency = lower(coalesce(p_currency, 'usd'))
      where id = v_rental.id
      returning * into v_rental;

    update public.rental_charge_items
      set status = 'paid',
          payment_provider = 'stripe',
          paid_at = coalesce(paid_at, now()),
          stripe_checkout_session_id = p_checkout_session_id,
          stripe_payment_intent_id = p_payment_intent_id,
          payment_currency = lower(coalesce(p_currency, 'usd')),
          updated_at = now()
      where rental_id = v_rental.id
        and included_in_initial_payment
        and status <> 'paid';

    perform public.ensure_rental_deposit_allocation(v_rental.id);

    insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
    values (
      v_rental.id,
      v_rental.user_id,
      null,
      'stripe_rental_payment_recorded',
      jsonb_build_object(
        'stripe_event_id', p_event_id,
        'checkout_session_id', p_checkout_session_id,
        'payment_intent_id', p_payment_intent_id,
        'amount_total', p_amount_total,
        'currency', lower(coalesce(p_currency, 'usd'))
      )
    );

    return jsonb_build_object('processed', true, 'target_type', 'rental', 'rental_id', v_rental.id);
  end if;

  if p_target_type = 'extension' then
    select *
      into v_request
      from public.rental_extension_requests
      where id = p_target_id
      for update;

    if not found then
      raise exception 'Extension request not found for Stripe checkout.';
    end if;

    if coalesce(v_request.stripe_checkout_session_id, p_checkout_session_id) <> p_checkout_session_id then
      raise exception 'Stripe checkout session does not match this extension request.';
    end if;

    if v_request.status <> 'approved_pending_payment'
       or v_request.payment_status <> 'pending' then
      raise exception 'Only approved unpaid extensions can be activated by Stripe.';
    end if;

    v_expected_amount := round(coalesce(v_request.extension_total_amount, 0) * 100)::integer;
    if p_amount_total <> v_expected_amount then
      raise exception 'Stripe payment amount does not match the extension total.';
    end if;

    select *
      into v_parent_rental
      from public.rentals
      where id = v_request.rental_id
      for update;

    if not found then
      raise exception 'Rental not found.';
    end if;

    if lower(coalesce(v_parent_rental.status, '')) in ('completed', 'cancelled', 'return_initiated') then
      raise exception 'This rental cannot be extended.';
    end if;

    perform pg_advisory_xact_lock(hashtext(v_parent_rental.vehicle_id::text));
    if v_request.request_kind = 'switch_car_continuation' then
      perform pg_advisory_xact_lock(hashtext(v_request.replacement_vehicle_id::text));
      select *
        into v_replacement
        from public.vehicles
        where id = v_request.replacement_vehicle_id
        for update;

      if not found then
        raise exception 'Replacement vehicle not found.';
      end if;

      if coalesce(lower(v_replacement.status), 'available') <> 'available' then
        raise exception 'Replacement vehicle is not available for a switch.';
      end if;
    end if;

    -- Replace the approved-extension calendar hold with the activated rental
    -- atomically. A failure rolls the hold release back with the transaction.
    perform public.release_extension_calendar_hold(v_request.id);

    if exists (
      select 1
      from public.rentals r
      where r.id <> v_parent_rental.id
        and r.vehicle_id = case when v_request.request_kind = 'switch_car_continuation'
          then v_request.replacement_vehicle_id else v_parent_rental.vehicle_id end
        and coalesce(lower(r.status), '') <> 'cancelled'
        and r.pickup_date is not null
        and r.return_date is not null
        and public.rentmect_periods_overlap(
          case when v_request.request_kind = 'switch_car_continuation'
            then public.rentmect_rental_timestamp(v_request.original_return_date, v_request.original_return_time)
            else public.rentmect_rental_timestamp(v_parent_rental.pickup_date, v_parent_rental.pickup_time)
          end,
          public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
          public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
          public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
        )
    ) or exists (
      select 1
      from public.vehicle_availability_blocks b
      where b.vehicle_id = case when v_request.request_kind = 'switch_car_continuation'
        then v_request.replacement_vehicle_id else v_parent_rental.vehicle_id end
        and coalesce(b.active, true)
        and coalesce(lower(b.block_type), 'unavailable') <> 'available'
        and public.rentmect_periods_overlap(
          public.rentmect_rental_timestamp(v_request.original_return_date, v_request.original_return_time),
          public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
          public.rentmect_rental_timestamp(b.start_date, b.start_time),
          public.rentmect_rental_timestamp(b.end_date, b.end_time)
        )
    ) then
      raise exception 'This extension conflicts with another booking or calendar block for the vehicle.';
    end if;

    if v_request.request_kind = 'switch_car_continuation' then
      insert into public.rentals (
        user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
        status, payment_status, deposit_status, paid_at,
        rental_total, tax_amount, security_deposit, deposit_held_amount,
        payment_provider, stripe_checkout_session_id, stripe_payment_intent_id,
        stripe_customer_id, payment_amount_cents, payment_currency
      ) values (
        v_parent_rental.user_id, v_replacement.id,
        v_request.original_return_date, v_request.requested_return_date,
        v_request.original_return_time, v_request.requested_return_time,
        'documents_needed', 'paid', 'held', now(),
        coalesce(v_request.extension_rental_amount, 0),
        coalesce(v_request.extension_tax_amount, 0),
        coalesce(v_request.replacement_deposit_required, 0),
        coalesce(v_request.replacement_deposit_required, 0),
        'stripe',
        p_checkout_session_id,
        p_payment_intent_id,
        p_customer_id,
        p_amount_total,
        lower(coalesce(p_currency, 'usd'))
      ) returning * into v_new_rental;

      perform public.transfer_rental_deposit_allocations(
        v_parent_rental.id,
        v_new_rental.id,
        coalesce(v_request.replacement_deposit_required, 0),
        'stripe',
        p_payment_intent_id
      );
    else
      update public.rentals
        set return_date = v_request.requested_return_date,
            return_time = v_request.requested_return_time,
            rental_total = coalesce(rental_total, 0) + coalesce(v_request.extension_rental_amount, 0),
            tax_amount = coalesce(tax_amount, 0) + coalesce(v_request.extension_tax_amount, 0)
        where id = v_parent_rental.id
        returning * into v_parent_rental;
    end if;

    update public.rental_extension_requests
      set status = 'activated',
          payment_status = 'paid',
          paid_at = now(),
          activated_at = now(),
          replacement_rental_id = coalesce(v_new_rental.id, replacement_rental_id),
          payment_provider = 'stripe',
          stripe_checkout_session_id = p_checkout_session_id,
          stripe_payment_intent_id = p_payment_intent_id,
          stripe_customer_id = p_customer_id,
          payment_amount_cents = p_amount_total,
          payment_currency = lower(coalesce(p_currency, 'usd')),
          updated_at = now()
      where id = v_request.id
      returning * into v_request;

    insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
    values (
      v_parent_rental.id,
      v_parent_rental.user_id,
      null,
      case when v_request.request_kind = 'switch_car_continuation'
        then 'stripe_vehicle_switch_payment_recorded'
        else 'stripe_rental_extension_payment_recorded'
      end,
      jsonb_build_object(
        'stripe_event_id', p_event_id,
        'extension_request_id', v_request.id,
        'checkout_session_id', p_checkout_session_id,
        'payment_intent_id', p_payment_intent_id,
        'replacement_rental_id', v_new_rental.id,
        'extension_total_amount', v_request.extension_total_amount
      )
    );

    return jsonb_build_object(
      'processed', true,
      'target_type', 'extension',
      'extension_request_id', v_request.id,
      'replacement_rental_id', v_new_rental.id
    );
  end if;

  raise exception 'Unsupported Stripe payment target type.';
end;
$$;

revoke all on function public.record_stripe_checkout_payment(text, text, text, uuid, text, text, text, integer, text, jsonb) from public;
grant execute on function public.record_stripe_checkout_payment(text, text, text, uuid, text, text, text, integer, text, jsonb) to service_role;
