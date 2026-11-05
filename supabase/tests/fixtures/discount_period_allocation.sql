create role anon;create role authenticated;create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;
create table public.email_outbox("id" uuid primary key default gen_random_uuid(),
"event_key" text,
"email_type" text,
"template_id" uuid,
"rental_id" uuid,
"user_id" uuid,
"recipient_email" text,
"recipient_name" text,
"payload" jsonb,
"status" text,
"attempts" integer default 0,
"next_attempt_at" timestamp with time zone,
"provider_message_id" text,
"last_error" text,
"created_at" timestamp with time zone default now(),
"updated_at" timestamp with time zone,
"sent_at" timestamp with time zone);
create table public.email_templates("id" uuid primary key default gen_random_uuid(),
"template_key" text,
"name" text,
"category" text,
"trigger_key" text,
"subject" text,
"preheader" text,
"html_body" text,
"text_body" text,
"enabled" boolean default false,
"version" integer default 0,
"created_by" uuid,
"created_at" timestamp with time zone default now(),
"updated_at" timestamp with time zone);
create table public.profiles("id" uuid primary key default gen_random_uuid(),
"full_name" text,
"phone" text,
"address" text,
"created_at" timestamp without time zone default now(),
"role" text,
"email" text,
"phone_verified" boolean default false,
"phone_verified_at" timestamp with time zone,
"phone_verification_method" text,
"phone_verification_updated_at" timestamp with time zone,
"admin_notes" text,
"blocked_customer" boolean default false,
"customer_status" text,
"block_reason" text,
"blocked_at" timestamp with time zone,
"date_of_birth" date,
"drivers_license_number" text,
"drivers_license_state" text,
"insurance_provider" text,
"insurance_policy_number" text,
"stripe_identity_verification_session_id" text,
"identity_verification_status" text,
"identity_verified_at" timestamp with time zone,
"identity_verification_updated_at" timestamp with time zone,
"identity_verification_error_code" text,
"identity_verification_livemode" boolean default false,
"intended_vehicle_use" text,
"email_marketing_opt_in" boolean default false,
"email_marketing_opted_in_at" timestamp with time zone,
"email_marketing_unsubscribed_at" timestamp with time zone,
"emergency_override_authorized" boolean default false,
"sms_transactional_opt_in" boolean default false,
"sms_transactional_opted_in_at" timestamp with time zone,
"sms_transactional_opted_out_at" timestamp with time zone,
"sms_transactional_consent_source" text,
"sms_transactional_consent_version" text,
"sms_transactional_consent_text" text,
"identity_verification_method" text,
"identity_verified_by" uuid,
"customer_deleted_at" timestamp with time zone,
"customer_deleted_by" uuid,
"staff_role" text);
create table public.rental_admin_extension_revisions("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"extension_id" uuid,
"actor_id" uuid,
"request" jsonb,
"financial_effect" jsonb,
"created_at" timestamp with time zone default now());
create table public.rental_admin_extensions("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"actor_id" uuid,
"recorded_at" timestamp with time zone,
"starts_at" timestamp with time zone,
"ends_at" timestamp with time zone,
"daily_rate" numeric default 0,
"billing_units" integer default 0,
"markup_percentage" numeric default 0,
"rental_amount" numeric default 0,
"tax_amount" numeric default 0,
"reason" text,
"request" jsonb,
"financial_effect" jsonb);
create table public.rental_amendments("id" uuid primary key default gen_random_uuid(),
"idempotency_key" uuid,
"rental_id" uuid,
"actor_id" uuid,
"reason" text,
"rental_state" text,
"old_values" jsonb,
"new_values" jsonb,
"pricing_delta" numeric default 0,
"deposit_delta" numeric default 0,
"total_delta" numeric default 0,
"settlement_status" text,
"adjustment_charge_id" uuid,
"credit_amount" numeric default 0,
"requires_customer_resign" boolean default false,
"created_at" timestamp with time zone default now(),
"invoice_total_before" numeric default 0,
"invoice_total_after" numeric default 0,
"net_paid_at_amendment" numeric default 0,
"balance_due_before" numeric default 0,
"balance_due_after" numeric default 0,
"credit_due_after" numeric default 0,
"canonical_settlement_status" text);
create table public.rental_audit_events("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"user_id" uuid,
"actor_id" uuid,
"event_type" text,
"event_payload" jsonb,
"created_at" timestamp with time zone default now());
create table public.rental_charge_items("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"user_id" uuid,
"service_fee_id" uuid,
"name" text,
"charge_type" text,
"description" text,
"amount" numeric default 0,
"taxable" boolean default false,
"tax_amount" numeric default 0,
"total_amount" numeric default 0,
"included_in_initial_payment" boolean default false,
"status" text,
"payment_provider" text,
"stripe_checkout_session_id" text,
"stripe_payment_intent_id" text,
"payment_amount_cents" integer default 0,
"payment_currency" text,
"paid_at" timestamp with time zone,
"created_by" uuid,
"created_at" timestamp with time zone default now(),
"updated_at" timestamp with time zone,
"stripe_customer_id" text,
"admin_charge_attempts" integer default 0,
"admin_charge_attempted_at" timestamp with time zone,
"last_admin_charge_error" text,
"source_type" text,
"source_reference" text,
"external_payment_method" text,
"external_payment_reference" text,
"external_payment_recorded_by" uuid,
"external_toll_receipt_id" uuid,
"checkout_creation_token" uuid);
create table public.rental_extension_requests("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"user_id" uuid,
"requested_return_date" date,
"requested_return_time" text,
"status" text,
"customer_note" text,
"admin_note" text,
"decided_by" uuid,
"decided_at" timestamp with time zone,
"created_at" timestamp with time zone default now(),
"updated_at" timestamp with time zone,
"payment_status" text,
"original_return_date" date,
"original_return_time" text,
"extension_days" integer default 0,
"extension_rental_amount" numeric default 0,
"extension_tax_amount" numeric default 0,
"extension_total_amount" numeric default 0,
"paid_at" timestamp with time zone,
"activated_at" timestamp with time zone,
"request_kind" text,
"replacement_vehicle_id" uuid,
"replacement_rental_id" uuid,
"payment_provider" text,
"stripe_checkout_session_id" text,
"stripe_payment_intent_id" text,
"stripe_customer_id" text,
"payment_amount_cents" integer default 0,
"payment_currency" text,
"extension_deposit_amount" numeric default 0,
"existing_deposit_held" numeric default 0,
"replacement_deposit_required" numeric default 0,
"deposit_carried_amount" numeric default 0,
"deposit_increase_amount" numeric default 0,
"deposit_decrease_amount" numeric default 0,
"payment_due_at" timestamp with time zone,
"approval_sms_status" text,
"approval_sms_attempts" integer default 0,
"approval_sms_next_attempt_at" timestamp with time zone,
"approval_sms_sent_at" timestamp with time zone,
"approval_sms_last_error" text,
"approval_email_queued_at" timestamp with time zone,
"agreed_daily_rate" numeric default 0,
"agreed_markup_percentage" numeric default 0,
"pricing_reason" text);
create table public.rental_pricing_periods("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"starts_at" timestamp with time zone,
"ends_at" timestamp with time zone,
"daily_rate" numeric default 0,
"billing_units" numeric default 0,
"markup_percentage" numeric default 0,
"rental_amount" numeric default 0,
"tax_amount" numeric default 0,
"source" text,
"extension_request_id" uuid,
"created_at" timestamp with time zone default now(),
"admin_extension_id" uuid);
create table public.rental_step_completions("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"user_id" uuid,
"step_key" text,
"completion_source" text,
"note" text,
"metadata" jsonb,
"completed_by" uuid,
"completed_at" timestamp with time zone,
"updated_at" timestamp with time zone);
create table public.rental_vehicle_swaps("id" uuid primary key default gen_random_uuid(),
"rental_id" uuid,
"vehicle_id" uuid,
"effective_at" timestamp with time zone,
"recorded_at" timestamp with time zone,
"actor_id" uuid,
"swap_kind" text,
"reason" text,
"request" jsonb,
"financial_effect" jsonb);
create table public.rentals("id" uuid primary key default gen_random_uuid(),
"user_id" uuid,
"vehicle_id" uuid,
"pickup_date" date,
"return_date" date,
"pickup_time" text,
"return_time" text,
"status" text,
"rental_total" numeric default 0,
"tax_amount" numeric default 0,
"security_deposit" numeric default 0,
"stripe_payment_intent_id" text,
"stripe_deposit_intent_id" text,
"agreement_signed" boolean default false,
"mileage_out" integer default 0,
"mileage_in" integer default 0,
"fuel_out" text,
"fuel_in" text,
"created_at" timestamp with time zone default now(),
"is_mock" boolean default false,
"payment_status" text,
"deposit_status" text,
"stripe_checkout_session_id" text,
"paid_at" timestamp with time zone,
"agreement_version" text,
"agreement_snapshot" text,
"agreement_hash" text,
"agreement_signed_at" timestamp with time zone,
"agreement_signature_name" text,
"agreement_ip" text,
"agreement_user_agent" text,
"mileage_policy" text,
"cancellation_terms" text,
"admin_notes" text,
"blocked_customer" boolean default false,
"chargeback_count" integer default 0,
"late_return_count" integer default 0,
"deposit_held_amount" numeric default 0,
"deposit_released_amount" numeric default 0,
"payment_provider" text,
"stripe_customer_id" text,
"payment_amount_cents" integer default 0,
"payment_currency" text,
"starting_mileage" integer default 0,
"ending_mileage" integer default 0,
"miles_driven" integer default 0,
"deposit_release_due_at" timestamp with time zone,
"deposit_release_attempted_at" timestamp with time zone,
"deposit_released_at" timestamp with time zone,
"deposit_refund_id" text,
"deposit_release_reason" text,
"deposit_release_error" text,
"checkout_expires_at" timestamp with time zone,
"base_rental_total" numeric default 0,
"under_25_markup_percentage" numeric default 0,
"under_25_markup_amount" numeric default 0,
"base_security_deposit" numeric default 0,
"under_25_deposit_adjustment_type" text,
"under_25_deposit_adjustment_value" numeric default 0,
"service_fee_total" numeric default 0,
"taxable_service_fee_total" numeric default 0,
"service_fee_tax_amount" numeric default 0,
"customer_name_snapshot" text,
"customer_email_snapshot" text,
"customer_phone_snapshot" text,
"customer_auth_deleted_at" timestamp with time zone,
"deposit_source_rental_id" uuid,
"deposit_transferred_to_rental_id" uuid,
"deposit_carried_amount" numeric default 0,
"deposit_increase_amount" numeric default 0,
"deposit_decrease_refund_due" numeric default 0,
"admin_payment_collection_preference" text,
"updated_at" timestamp with time zone,
"booking_source" text,
"source_pending_booking_id" uuid,
"payment_due_at" timestamp with time zone,
"cancelled_at" timestamp with time zone,
"cancelled_by" uuid,
"cancellation_reason" text,
"trip_change_intent" text,
"return_initiated_at" timestamp with time zone,
"inspection_completed_at" timestamp with time zone,
"pre_discount_rental_total" numeric default 0,
"discount_code_id" uuid,
"discount_code" text,
"discount_amount" numeric default 0,
"discount_reserved" boolean default false,
"discount_waives_security_deposit" boolean default false,
"pre_discount_service_fee_total" numeric default 0,
"pre_discount_tax_amount" numeric default 0,
"pre_discount_security_deposit" numeric default 0,
"external_payment_amount" numeric default 0,
"external_payment_method" text,
"external_payment_recorded_at" timestamp with time zone,
"external_payment_recorded_by" uuid,
"minimum_rental_days_applied" integer default 0,
"advance_notice_minutes_applied" integer default 0,
"actual_duration_minutes" integer default 0,
"billable_days" integer default 0,
"manual_discount_amount" numeric default 0,
"manual_discount_tax_savings" numeric default 0,
"manual_discount_type" text,
"manual_discount_value" numeric default 0,
"pre_manual_discount_rental_total" numeric default 0,
"pre_manual_discount_tax_amount" numeric default 0,
"manual_discount_reason" text,
"manual_discount_applied_by" uuid,
"manual_discount_applied_at" timestamp with time zone,
"cancelled_before_pickup_at" timestamp with time zone,
"cancellation_credit_amount" numeric default 0,
"merchant_id" uuid,
"merchant_employee_id" uuid,
"merchant_documents_due_at" timestamp with time zone,
"merchant_reservation_number" text);
create table public.vehicles("id" uuid primary key default gen_random_uuid(),
"name" text,
"brand" text,
"model" text,
"vehicle_type" text,
"plate_number" text,
"vin" text,
"daily_rate" numeric default 0,
"security_deposit" numeric default 0,
"included_miles_per_day" integer default 0,
"extra_mile_rate" numeric default 0,
"status" text,
"image_url" text,
"created_at" timestamp with time zone default now(),
"updated_at" timestamp with time zone,
"category" text,
"mileage_included" integer default 0,
"extra_mileage_rate" numeric default 0,
"is_active" boolean default false,
"display_order" integer default 0,
"current_mileage" integer default 0,
"description" text,
"features" text[],
"image_urls" text[],
"original_mileage" integer default 0,
"maintenance_interval_miles" integer default 0,
"last_maintenance_mileage" integer default 0,
"next_maintenance_mileage" integer default 0,
"maintenance_completed_at" timestamp with time zone,
"published" boolean default false,
"maintenance_lock_active" boolean default false,
"maintenance_lock_reason" text,
"maintenance_lock_schedule_id" uuid,
"maintenance_locked_at" timestamp with time zone,
"maintenance_prelock_status" text,
"maintenance_override_until" timestamp with time zone,
"maintenance_override_reason" text,
"maintenance_override_admin_id" uuid,
"tollspot_enabled" boolean default false,
"tollspot_vehicle_type" text,
"plate_state" text,
"plate_country" text,
"plate_assigned_at" timestamp with time zone,
"model_year" integer default 0);
create unique index on email_outbox(event_key);
create table test_receipts(rental_id uuid,amount numeric);
create function public.is_admin() returns boolean language sql as $$select exists(select 1 from profiles where id=auth.uid() and role='admin')$$;
create function public.rentmect_rental_net_paid_amount(uuid) returns numeric language sql as $$select coalesce(sum(amount),0) from test_receipts where rental_id=$1$$;
create function public.rentmect_rental_timestamp(date,text) returns timestamp language sql immutable as $$select $1+$2::time$$;
create function public.rentmect_billable_days(date,text,date,text) returns integer language sql immutable as $$select greatest(1,ceil(extract(epoch from (($3+$4::time)-($1+$2::time)))/86400))::integer$$;
CREATE OR REPLACE FUNCTION public.rentmect_pricing_snapshot(p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.rentals%rowtype; e record; result jsonb; units numeric; rate numeric;
  baseline_end timestamptz; baseline_date date; baseline_time text; amount numeric; tax numeric;
begin
  select jsonb_agg(p order by starts_at) into result from public.rental_pricing_periods p where rental_id=p_rental_id;
  if result is not null then return result; end if;
  select * into strict r from public.rentals where id=p_rental_id;
  select original_return_date,original_return_time into baseline_date,baseline_time from public.rental_extension_requests
    where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated'
    order by public.rentmect_rental_timestamp(original_return_date,original_return_time) limit 1;
  baseline_date:=coalesce(baseline_date,r.return_date); baseline_time:=coalesce(baseline_time,r.return_time);
  baseline_end:=public.rentmect_rental_timestamp(baseline_date,baseline_time) at time zone 'America/New_York';
  units:=public.rentmect_billable_days(r.pickup_date,r.pickup_time,baseline_date,baseline_time);
  select coalesce(r.rental_total,0)-coalesce(sum(extension_rental_amount),0),coalesce(r.tax_amount,0)-coalesce(sum(extension_tax_amount),0)
    into amount,tax from public.rental_extension_requests where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated';
  if amount<0 or tax<0 then raise exception 'Legacy extension charges exceed the invoice. Reconcile this rental before swapping.'; end if;
  rate:=coalesce(r.base_rental_total,(amount+coalesce(r.discount_amount,0)+coalesce(r.manual_discount_amount,0))/(1+coalesce(r.under_25_markup_percentage,0)/100))/units;
  result:=jsonb_build_array(jsonb_build_object('rental_id',r.id,
    'starts_at',public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
    'ends_at',baseline_end,'daily_rate',rate,'billing_units',units,'markup_percentage',coalesce(r.under_25_markup_percentage,0),
    'rental_amount',amount,'tax_amount',tax,'source','booking_snapshot'));
  for e in select * from public.rental_extension_requests where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated'
    order by public.rentmect_rental_timestamp(original_return_date,original_return_time) loop
    units:=coalesce(e.extension_days,public.rentmect_billable_days(e.original_return_date,e.original_return_time,e.requested_return_date,e.requested_return_time));
    result:=result||jsonb_build_array(jsonb_build_object('rental_id',r.id,
      'starts_at',public.rentmect_rental_timestamp(e.original_return_date,e.original_return_time) at time zone 'America/New_York',
      'ends_at',public.rentmect_rental_timestamp(e.requested_return_date,e.requested_return_time) at time zone 'America/New_York',
      'daily_rate',coalesce(e.agreed_daily_rate,e.extension_rental_amount/units/(1+coalesce(r.under_25_markup_percentage,0)/100)),
      'billing_units',units,'markup_percentage',coalesce(e.agreed_markup_percentage,r.under_25_markup_percentage,0),
      'rental_amount',e.extension_rental_amount,'tax_amount',e.extension_tax_amount,'source','extension','extension_request_id',e.id));
  end loop;
  return result;
end; $function$
;
CREATE OR REPLACE FUNCTION public.rentmect_initialize_pricing_periods(p_rental_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  if exists(select 1 from public.rental_pricing_periods where rental_id=p_rental_id) then return; end if;
  insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,
    markup_percentage,rental_amount,tax_amount,source,extension_request_id)
  select rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source,extension_request_id
    from jsonb_populate_recordset(null::public.rental_pricing_periods,public.rentmect_pricing_snapshot(p_rental_id));
end; $function$
;
CREATE OR REPLACE FUNCTION public.admin_preview_manual_rental_discount(p_rental_id uuid, p_mode text, p_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.rentmect_guard_dated_rental()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e public.rental_extension_requests%rowtype; managed boolean; swapping boolean;
begin
  managed:=exists(select 1 from public.rental_pricing_periods where rental_id=old.id);
  swapping:=exists(select 1 from public.rental_vehicle_swaps where id::text=current_setting('rentmect.vehicle_swap',true)
    and rental_id=old.id and vehicle_id=new.vehicle_id);
  if old.status in ('active','rented','overdue','return_initiated','completed') or old.starting_mileage is not null or managed then
    if (new.pickup_date,new.pickup_time) is distinct from (old.pickup_date,old.pickup_time) then raise exception 'The original rental start cannot be changed after pickup.'; end if;
    if new.vehicle_id is distinct from old.vehicle_id and not swapping then raise exception 'Use the dedicated vehicle swap workflow with an effective time.'; end if;
  end if;

  if exists(select 1 from public.rental_admin_extension_revisions v
   where v.id::text=current_setting('rentmect.extension_revision',true) and v.rental_id=old.id
   and (v.financial_effect->>'old_ends_at')::timestamptz=(public.rentmect_rental_timestamp(old.return_date,old.return_time) at time zone 'America/New_York')
   and (v.financial_effect->>'ends_at')::timestamptz=(public.rentmect_rental_timestamp(new.return_date,new.return_time) at time zone 'America/New_York')) then return new; end if;
  if (new.return_date,new.return_time) is distinct from (old.return_date,old.return_time)
    and (managed or old.status in ('active','rented','overdue','return_initiated')) then
    
    if exists(select 1 from public.rental_admin_extensions extension
      where extension.id::text=current_setting('rentmect.admin_extension',true) and extension.rental_id=old.id
      and extension.starts_at=(public.rentmect_rental_timestamp(old.return_date,old.return_time) at time zone 'America/New_York')
      and extension.ends_at=(public.rentmect_rental_timestamp(new.return_date,new.return_time) at time zone 'America/New_York')) then
      perform public.rentmect_initialize_pricing_periods(old.id);
      insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,
        markup_percentage,rental_amount,tax_amount,source,admin_extension_id)
        select rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,'extension',id
        from public.rental_admin_extensions where id::text=current_setting('rentmect.admin_extension',true);
      new.rental_total:=(select sum(rental_amount) from public.rental_pricing_periods where rental_id=old.id);
      new.tax_amount:=(select sum(tax_amount) from public.rental_pricing_periods where rental_id=old.id);
      return new;
    end if;
    select * into e from public.rental_extension_requests where rental_id=old.id
  
      and id::text=current_setting('rentmect.extension_activation',true)
      and status='approved_pending_payment' and request_kind='same_vehicle_extension'
      and (original_return_date,original_return_time)=(old.return_date,old.return_time)
      and (requested_return_date,requested_return_time)=(new.return_date,new.return_time) for update;
    if not found then raise exception 'Use a separately quoted extension to change a started rental return.'; end if;
    perform public.rentmect_initialize_pricing_periods(old.id);
    insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source,extension_request_id)
      values(old.id,public.rentmect_rental_timestamp(old.return_date,old.return_time) at time zone 'America/New_York',
        public.rentmect_rental_timestamp(new.return_date,new.return_time) at time zone 'America/New_York',
        coalesce(e.agreed_daily_rate,e.extension_rental_amount/nullif(e.extension_days,0)/(1+coalesce(old.under_25_markup_percentage,0)/100)),
        e.extension_days,coalesce(e.agreed_markup_percentage,old.under_25_markup_percentage,0),e.extension_rental_amount,e.extension_tax_amount,'extension',e.id);
    new.rental_total:=old.rental_total+e.extension_rental_amount;
    new.tax_amount:=old.tax_amount+e.extension_tax_amount;
  elsif (managed or old.status in ('active','rented','overdue','return_initiated','completed')) and not swapping and (new.rental_total,new.tax_amount,new.base_rental_total,new.discount_amount,new.manual_discount_amount)
    is distinct from (old.rental_total,old.tax_amount,old.base_rental_total,old.discount_amount,old.manual_discount_amount) then
    
    if (new.base_rental_total,new.discount_amount,new.service_fee_total,new.taxable_service_fee_total,new.security_deposit)
      is not distinct from (old.base_rental_total,old.discount_amount,old.service_fee_total,old.taxable_service_fee_total,old.security_deposit)
      and exists(select 1 from public.rental_amendments amendment
        where amendment.id::text=current_setting('rentmect.manual_discount_amendment',true)
          and amendment.rental_id=old.id
          and amendment.old_values @> jsonb_build_object('rental_total',old.rental_total,
            'tax_amount',old.tax_amount,'manual_discount_amount',old.manual_discount_amount)
          and amendment.new_values @> jsonb_build_object('rental_total',new.rental_total,
            'tax_amount',new.tax_amount,'manual_discount_amount',new.manual_discount_amount,
            'manual_discount_type',new.manual_discount_type,'manual_discount_value',new.manual_discount_value)) then
      -- Apply the explicitly requested whole-rental discount across the current
      -- periods. Cumulative rounding preserves the exact invoice cents. Rates,
      -- units, dates, original extension quotes, and payment records stay intact.
      -- Fully comped periods use agreed gross pricing (then units) as weights.
      with weights as (
        select id,starts_at,case
          when sum(rental_amount) over () > 0 then greatest(rental_amount,0)
          when sum(daily_rate*billing_units*(1+markup_percentage/100)) over () > 0
            then daily_rate*billing_units*(1+markup_percentage/100)
          else billing_units end as weight
        from public.rental_pricing_periods where rental_id=old.id
      ), shares as (
        select id,weight,sum(weight) over(order by starts_at,id) cumulative,
          sum(weight) over() total from weights
      )
      update public.rental_pricing_periods period
        set rental_amount=round(new.rental_total*shares.cumulative/shares.total,2)
            -round(new.rental_total*(shares.cumulative-shares.weight)/shares.total,2),
          tax_amount=round(new.tax_amount*shares.cumulative/shares.total,2)
            -round(new.tax_amount*(shares.cumulative-shares.weight)/shares.total,2)
        from shares where period.id=shares.id;
    else
      raise exception 'Dated rental pricing cannot be overwritten by a whole-rental edit.';
    end if;
  
  end if;
  return new;
end; $function$
;
CREATE OR REPLACE FUNCTION public.admin_apply_manual_rental_discount(p_rental_id uuid, p_mode text, p_value numeric, p_reason text, p_idempotency_key uuid, p_actor_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    if v_existing.rental_id<>p_rental_id or v_existing.reason is distinct from trim(p_reason)
      or (v_existing.new_values ? 'discount_request' and
        v_existing.new_values->'discount_request' is distinct from jsonb_build_object(
          'mode',p_mode,'value',p_value,'reason',trim(p_reason))) then
      raise exception 'Idempotency key already used for a different discount.';
    end if;
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


  if exists(select 1 from public.rental_charge_items where rental_id=p_rental_id
    and charge_type in ('rental_amendment','rental_installment')
    and status in ('pending','checkout_open','failed')
    and (status='checkout_open' or stripe_checkout_session_id is not null or stripe_payment_intent_id is not null))
    or (v_rental.paid_at is null and (v_rental.stripe_checkout_session_id is not null
      or v_rental.stripe_payment_intent_id is not null)) then
    raise exception 'Expire the open payment attempt through the protected discount action before saving.';
  end if;
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
      'discount_request',jsonb_build_object('mode',p_mode,'value',p_value,'reason',trim(p_reason)),
      'total', v_new_total
    ),
    round(v_total_delta, 2), 0, v_total_delta, v_settlement_status,
    case when v_settlement_status = 'customer_credit_due' then abs(v_total_delta) else 0 end,
    v_requires_resign
  ) returning * into v_amendment;

  
  -- Snapshot old customer extensions before discounting their combined invoice;
  -- reconstructing them from an already-discounted total could go negative.
  if v_rental.status in ('active','rented','overdue','return_initiated','completed') then
    perform public.rentmect_initialize_pricing_periods(v_rental.id);
  end if;
  update public.rental_amendments set old_values=old_values||jsonb_build_object(
    'pricing_periods',public.rentmect_pricing_snapshot(v_rental.id)) where id=v_amendment.id;
  perform set_config('rentmect.manual_discount_amendment',v_amendment.id::text,true);
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
  perform set_config('rentmect.manual_discount_amendment','',true);
  update public.rental_amendments set new_values=new_values||jsonb_build_object(
    'pricing_periods',public.rentmect_pricing_snapshot(v_rental.id))
    where id=v_amendment.id returning * into v_amendment;
  if v_requires_resign then
    delete from public.rental_step_completions where rental_id=v_rental.id and step_key='agreement';
  end if;
  

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
$function$
;
create trigger test_dated_guard before update on rentals for each row execute function rentmect_guard_dated_rental();
