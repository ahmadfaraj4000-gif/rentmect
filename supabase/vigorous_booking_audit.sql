-- Comprehensive, non-charging booking audit.
-- Run in Supabase SQL Editor after all migrations listed in LAUNCH_READINESS.md.
-- Every fixture and simulated payment is rolled back. No Stripe, Twilio,
-- SendGrid, Pushover, or Wheelbase network call is made.

begin;

do $$
declare
  v_customer_id uuid;
  v_admin_id uuid;
  v_vehicle_id uuid := gen_random_uuid();
  v_under25_id uuid;
  v_over25_id uuid;
  v_admin_rental public.rentals%rowtype;
  v_extension public.rental_extension_requests%rowtype;
  v_under25_extension public.rental_extension_requests%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_rejected boolean;
  v_available boolean;
  v_start date := current_date + 60;
  v_count integer;
begin
  select id into v_customer_id from public.profiles
  where coalesce(role, 'client') <> 'admin' order by created_at limit 1;
  select id into v_admin_id from public.profiles
  where role = 'admin' order by created_at limit 1;
  if v_customer_id is null then raise exception 'AUDIT SETUP: at least one customer profile is required.'; end if;
  if v_admin_id is null then raise exception 'AUDIT SETUP: at least one admin profile is required.'; end if;

  update public.service_fees set active = false;
  insert into public.service_fees (name, service_type, amount, taxable, active)
  values ('Audit taxable fee', 'audit_taxable', 25, true, true),
         ('Audit non-taxable fee', 'audit_non_taxable', 10, false, true);
  update public.under_25_pricing_settings set
    deposit_adjustment_enabled = true,
    deposit_adjustment_type = 'fixed',
    deposit_adjustment_value = 200,
    rental_markup_percentage = 10
  where id = true;

  insert into public.vehicles (
    id, name, brand, model, vehicle_type, daily_rate, security_deposit,
    status, description, features, image_urls, published
  ) values (
    v_vehicle_id, 'Rollback Vigorous Audit Vehicle', 'Rent Me CT', 'Audit',
    'Internal Test', 100, 300, 'available', 'Rollback-only audit fixture.',
    array['Audit fixture']::text[], array[]::text[], false
  );

  -- Age 24: 10% rental markup and $200 deposit adjustment.
  update public.profiles set date_of_birth = (current_date - interval '24 years')::date
  where id = v_customer_id;
  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, payment_status, deposit_status
  ) values (
    v_customer_id, v_vehicle_id, v_start, v_start + 2, '9:00 AM', '6:00 PM',
    'documents_needed', 'pending', 'pending'
  ) returning id into v_under25_id;

  if not exists (
    select 1 from public.rentals where id = v_under25_id
      and base_rental_total = 200 and rental_total = 220
      and under_25_markup_percentage = 10 and under_25_markup_amount = 20
      and base_security_deposit = 300 and security_deposit = 500
      and service_fee_total = 35 and service_fee_tax_amount = 1.59
      and tax_amount = 15.56
  ) then raise exception 'AUDIT FAILED: under-25 pricing/deposit/fee snapshot is incorrect.'; end if;
  if public.rentmect_rental_amount_due_cents(v_under25_id) <> 77056 then
    raise exception 'AUDIT FAILED: under-25 Stripe amount contract is not $770.56.';
  end if;
  select count(*) into v_count from public.rental_charge_items
  where rental_id = v_under25_id and included_in_initial_payment;
  if v_count <> 2 then raise exception 'AUDIT FAILED: active booking fees were not snapshotted.'; end if;

  -- Simulate a signed Stripe webhook. This writes only inside this rollback.
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform public.record_stripe_checkout_payment(
    'evt_audit_under25_' || replace(v_under25_id::text, '-', ''),
    'checkout.session.completed', 'rental', v_under25_id,
    'cs_audit_under25', 'pi_audit_under25', 'cus_audit_under25',
    77056, 'usd', '{}'::jsonb
  );
  if not exists (select 1 from public.rentals where id = v_under25_id and payment_status = 'paid' and payment_amount_cents = 77056) then
    raise exception 'AUDIT FAILED: under-25 Stripe ledger did not record the exact amount.';
  end if;
  if exists (select 1 from public.rental_charge_items where rental_id = v_under25_id and included_in_initial_payment and status <> 'paid') then
    raise exception 'AUDIT FAILED: initial booking fees were not marked paid with the rental.';
  end if;

  -- Added days retain the original under-25 percentage and require payment.
  insert into public.rental_extension_requests (
    rental_id, user_id, original_return_date, original_return_time,
    requested_return_date, requested_return_time, customer_note
  ) values (
    v_under25_id, v_customer_id, v_start + 2, '6:00 PM',
    v_start + 3, '6:00 PM', 'Rollback under-25 extension audit'
  ) returning * into v_under25_extension;
  perform set_config('request.jwt.claim.sub', v_admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select * into v_under25_extension from public.decide_admin_rental_extension(
    v_under25_extension.id, true, 'Audit under-25 approval'
  );
  if v_under25_extension.extension_rental_amount <> 110
     or v_under25_extension.extension_tax_amount <> 6.99
     or v_under25_extension.extension_total_amount <> 116.99 then
    raise exception 'AUDIT FAILED: under-25 extension did not preserve the 10%% markup. Actual rental=%, tax=%, total=%; rental markup snapshot=%',
      v_under25_extension.extension_rental_amount,
      v_under25_extension.extension_tax_amount,
      v_under25_extension.extension_total_amount,
      (select under_25_markup_percentage from public.rentals where id = v_under25_id);
  end if;
  perform public.cancel_admin_approved_extension(v_under25_extension.id);

  -- Exact age 25: no markup and the vehicle's $300 deposit.
  update public.profiles set date_of_birth = (current_date - interval '25 years')::date
  where id = v_customer_id;
  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, payment_status, deposit_status
  ) values (
    v_customer_id, v_vehicle_id, v_start + 10, v_start + 12, '9:00 AM', '6:00 PM',
    'documents_needed', 'pending', 'pending'
  ) returning id into v_over25_id;
  if not exists (
    select 1 from public.rentals where id = v_over25_id
      and base_rental_total = 200 and rental_total = 200
      and under_25_markup_amount = 0 and security_deposit = 300
      and service_fee_total = 35 and tax_amount = 14.29
  ) then raise exception 'AUDIT FAILED: age-25-plus pricing/deposit/fee snapshot is incorrect.'; end if;
  if public.rentmect_rental_amount_due_cents(v_over25_id) <> 54929 then
    raise exception 'AUDIT FAILED: 25-plus Stripe amount contract is not $549.29.';
  end if;

  -- Overlap and turnaround enforcement.
  v_rejected := false;
  begin
    insert into public.rentals (user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time, status)
    values (v_customer_id, v_vehicle_id, v_start + 10, v_start + 11, '10:00 AM', '5:00 PM', 'documents_needed');
  exception when others then v_rejected := position('Vehicle schedule conflict' in sqlerrm) > 0; end;
  if not v_rejected then raise exception 'AUDIT FAILED: overlapping rental was accepted.'; end if;

  v_rejected := false;
  begin
    insert into public.rentals (user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time, status)
    values (v_customer_id, v_vehicle_id, v_start + 12, v_start + 13, '8:59 PM', '6:00 PM', 'documents_needed');
  exception when others then v_rejected := position('Vehicle schedule conflict' in sqlerrm) > 0; end;
  if not v_rejected then raise exception 'AUDIT FAILED: a 2:59 turnaround was accepted.'; end if;

  select available into v_available
  from public.get_admin_calendar_fleet_availability(v_start + 10, '10:00 AM', v_start + 11, '5:00 PM')
  where vehicle_id = v_vehicle_id;
  if coalesce(v_available, true) then raise exception 'AUDIT FAILED: admin calendar RPC did not reflect customer booking.'; end if;

  -- Extension request -> Pushover queue -> approval -> visible calendar hold.
  insert into public.rental_extension_requests (
    rental_id, user_id, original_return_date, original_return_time,
    requested_return_date, requested_return_time, customer_note
  ) values (
    v_over25_id, v_customer_id, v_start + 12, '6:00 PM',
    v_start + 13, '6:00 PM', 'Rollback extension audit'
  ) returning * into v_extension;
  if not exists (select 1 from public.admin_notification_events where event_type = 'extension_requested' and source_id = v_extension.id) then
    raise exception 'AUDIT FAILED: extension request did not queue a Pushover event.';
  end if;
  perform set_config('request.jwt.claim.sub', v_admin_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select * into v_extension from public.decide_admin_rental_extension(v_extension.id, true, 'Audit approval');
  if v_extension.status <> 'approved_pending_payment' or v_extension.extension_total_amount <> 106.35 then
    raise exception 'AUDIT FAILED: extension approval or amount is incorrect.';
  end if;
  if not exists (
    select 1 from public.email_outbox
    where event_key = 'extension_payment_due:' || v_extension.id::text
  ) then raise exception 'AUDIT FAILED: approved extension did not queue the customer payment email.'; end if;
  if not exists (
    select 1 from public.vehicle_availability_blocks
    where active and notes like '%[EXTENSION_REQUEST=' || v_extension.id::text || ']%'
  ) then raise exception 'AUDIT FAILED: approved extension did not create a calendar hold.'; end if;
  select available into v_available
  from public.get_admin_calendar_fleet_availability(v_start + 12, '7:00 PM', v_start + 13, '5:00 PM')
  where vehicle_id = v_vehicle_id;
  if coalesce(v_available, true) then raise exception 'AUDIT FAILED: approved extension hold is absent from fleet availability.'; end if;
  perform public.record_admin_local_rental_extension_payment(v_extension.id);
  if not exists (select 1 from public.rentals where id = v_over25_id and return_date = v_start + 13 and return_time = '6:00 PM') then
    raise exception 'AUDIT FAILED: paid extension did not update the rental/calendar source.';
  end if;
  if exists (select 1 from public.vehicle_availability_blocks where active and notes like '%[EXTENSION_REQUEST=' || v_extension.id::text || ']%') then
    raise exception 'AUDIT FAILED: activated extension left a stale calendar hold.';
  end if;

  -- Admin booking uses the same pricing/calendar protection and queues the
  -- customer completion email. It remains blocked from pickup until workflow completion.
  select * into v_admin_rental from public.admin_create_manual_rental(
    v_customer_id, v_vehicle_id, v_start + 20, v_start + 22, '9:00 AM', '6:00 PM'
  );
  if v_admin_rental.status <> 'documents_needed' or v_admin_rental.payment_status <> 'pending'
     or coalesce(v_admin_rental.agreement_signed, false) then
    raise exception 'AUDIT FAILED: admin booking bypassed customer completion requirements.';
  end if;
  perform public.sync_rental_ready_for_pickup_global(v_admin_rental.id);
  if exists (select 1 from public.rentals where id = v_admin_rental.id and status = 'ready_for_pickup') then
    raise exception 'AUDIT FAILED: incomplete admin booking was released without identity/documents/agreement/payment.';
  end if;
  if not exists (select 1 from public.email_outbox where event_key = 'admin_booking_action_required:' || v_admin_rental.id::text) then
    raise exception 'AUDIT FAILED: admin booking did not queue customer completion email.';
  end if;
  if not exists (select 1 from public.admin_notification_events where event_type = 'new_booking' and rental_id = v_admin_rental.id) then
    raise exception 'AUDIT FAILED: admin booking did not queue calendar/operations notification.';
  end if;

  -- Booking-specific toll/add-on and exact Stripe charge amount.
  select * into v_charge from public.admin_add_rental_charge(
    v_admin_rental.id, 'Audit toll', 'toll', 10, true, 'Rollback-only toll'
  );
  if v_charge.tax_amount <> 0.64 or v_charge.total_amount <> 10.64 or v_charge.status <> 'pending' then
    raise exception 'AUDIT FAILED: admin-added charge amount/tax is incorrect.';
  end if;
  if not exists (select 1 from public.email_outbox where event_key = 'additional_charge_due:' || v_charge.id::text) then
    raise exception 'AUDIT FAILED: additional charge did not queue a customer payment email.';
  end if;
  perform set_config('request.jwt.claim.role', 'service_role', true);
  select * into v_charge from public.record_stripe_rental_charge_payment(
    v_charge.id, 'cs_audit_charge', 'pi_audit_charge', 1064, 'usd'
  );
  if v_charge.status <> 'paid' or v_charge.payment_amount_cents <> 1064 then
    raise exception 'AUDIT FAILED: additional charge payment ledger is incorrect.';
  end if;
  if not exists (select 1 from public.email_outbox where event_key = 'additional_charge_paid:' || v_charge.id::text) then
    raise exception 'AUDIT FAILED: paid additional charge did not queue a customer receipt.';
  end if;

  raise notice 'PASS: under-25, 25+, Stripe totals, fees, overlaps, turnaround, extension, Pushover queue, admin booking, completion email, calendar, and add-on charge tests passed.';
end;
$$;

select 'PASS — vigorous rollback audit completed; no charge, rental, email, notification, or vehicle was retained.' as audit_result;

rollback;
