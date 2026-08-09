-- Internal charge templates, post-booking charges, manual-booking completion
-- emails, and extension notification/calendar holds.
-- Run after vehicle_deposits_and_under25_pricing.sql,
-- local_payment_and_extensions.sql, email_automation_and_campaigns.sql,
-- admin_pushover_notifications.sql, and booking_integrity_guards.sql.

alter table public.rentals
  add column if not exists service_fee_total numeric not null default 0,
  add column if not exists taxable_service_fee_total numeric not null default 0,
  add column if not exists service_fee_tax_amount numeric not null default 0;

create table if not exists public.rental_charge_items (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  service_fee_id uuid references public.service_fees(id) on delete set null,
  name text not null,
  charge_type text not null default 'add_on',
  description text,
  amount numeric(10,2) not null check (amount > 0),
  taxable boolean not null default true,
  tax_amount numeric(10,2) not null default 0 check (tax_amount >= 0),
  total_amount numeric(10,2) not null check (total_amount > 0),
  included_in_initial_payment boolean not null default false,
  status text not null default 'pending'
    check (status in ('pending', 'checkout_open', 'paid', 'waived', 'failed')),
  payment_provider text,
  stripe_customer_id text,
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  admin_charge_attempts integer not null default 0 check (admin_charge_attempts >= 0),
  admin_charge_attempted_at timestamptz,
  last_admin_charge_error text,
  payment_amount_cents integer,
  payment_currency text default 'usd',
  paid_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.rental_charge_items
  add column if not exists stripe_customer_id text,
  add column if not exists admin_charge_attempts integer not null default 0,
  add column if not exists admin_charge_attempted_at timestamptz,
  add column if not exists last_admin_charge_error text;

create index if not exists rental_charge_items_rental_idx
  on public.rental_charge_items (rental_id, status, created_at);

alter table public.rental_charge_items enable row level security;

drop policy if exists "Customers read their rental charges" on public.rental_charge_items;
create policy "Customers read their rental charges"
on public.rental_charge_items for select to authenticated
using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Admins manage rental charges" on public.rental_charge_items;
create policy "Admins manage rental charges"
on public.rental_charge_items for all to authenticated
using (public.is_admin()) with check (public.is_admin());

grant select on public.rental_charge_items to authenticated;

create or replace function public.apply_rentmect_rental_pricing()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_birth_date date;
  v_daily_rate numeric;
  v_vehicle_deposit numeric;
  v_days integer;
  v_base_rental numeric;
  v_under_25 boolean := false;
  v_settings public.under_25_pricing_settings%rowtype;
begin
  if tg_op = 'UPDATE' and lower(coalesce(old.payment_status, 'pending')) = 'paid' then
    return new;
  end if;

  select profiles.date_of_birth into v_birth_date
  from public.profiles profiles where profiles.id = new.user_id;
  select coalesce(vehicles.daily_rate, 0), coalesce(vehicles.security_deposit, 0)
    into v_daily_rate, v_vehicle_deposit
  from public.vehicles vehicles where vehicles.id = new.vehicle_id;
  if v_daily_rate is null then return new; end if;

  v_days := greatest(coalesce(new.return_date - new.pickup_date, 0), 0);
  v_base_rental := round(v_daily_rate * v_days, 2);
  v_under_25 := v_birth_date is not null
    and age((now() at time zone 'America/New_York')::date, v_birth_date) < interval '25 years';
  select * into v_settings from public.under_25_pricing_settings where id = true;

  new.base_rental_total := v_base_rental;
  new.rental_total := case when v_under_25
    then public.rentmect_calculate_under25_rental(v_base_rental)
    else v_base_rental end;
  new.under_25_markup_percentage := case when v_under_25
    then coalesce(v_settings.rental_markup_percentage, 10) else 0 end;
  new.under_25_markup_amount := round(new.rental_total - v_base_rental, 2);
  new.service_fee_total := 0;
  new.taxable_service_fee_total := 0;
  new.service_fee_tax_amount := 0;
  new.tax_amount := round(new.rental_total * 0.0635, 2);
  new.base_security_deposit := v_vehicle_deposit;
  new.security_deposit := case when v_under_25
    then public.rentmect_calculate_under25_deposit(v_vehicle_deposit)
    else v_vehicle_deposit end;
  new.under_25_deposit_adjustment_type := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_type, 'fixed') else null end;
  new.under_25_deposit_adjustment_value := case
    when v_under_25 and coalesce(v_settings.deposit_adjustment_enabled, true)
      then coalesce(v_settings.deposit_adjustment_value, 200) else 0 end;
  return new;
end;
$$;

create or replace function public.snapshot_rental_service_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  return new;
end;
$$;

drop trigger if exists rentals_snapshot_service_fees on public.rentals;

create or replace function public.rentmect_rental_amount_due_cents(p_rental_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select round((
    coalesce(rental_total, 0) + coalesce(service_fee_total, 0) +
    coalesce(tax_amount, 0) + coalesce(security_deposit, 0)
  ) * 100)::integer
  from public.rentals where id = p_rental_id;
$$;

revoke all on function public.rentmect_rental_amount_due_cents(uuid) from public;
grant execute on function public.rentmect_rental_amount_due_cents(uuid) to authenticated, service_role;

create or replace function public.admin_add_rental_charge(
  p_rental_id uuid,
  p_name text,
  p_charge_type text,
  p_amount numeric,
  p_taxable boolean default true,
  p_description text default null
) returns public.rental_charge_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_tax numeric;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Charge name is required.'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'Charge amount must be greater than zero.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then raise exception 'Cancelled rentals cannot receive charges.'; end if;
  v_tax := case when coalesce(p_taxable, true) then round(p_amount * 0.0635, 2) else 0 end;
  insert into public.rental_charge_items (
    rental_id, user_id, name, charge_type, description, amount, taxable,
    tax_amount, total_amount, included_in_initial_payment, status, created_by
  ) values (
    v_rental.id, v_rental.user_id, trim(p_name),
    coalesce(nullif(trim(p_charge_type), ''), 'add_on'), nullif(trim(p_description), ''),
    round(p_amount, 2), coalesce(p_taxable, true), v_tax,
    round(p_amount + v_tax, 2), false, 'pending', v_admin_id
  ) returning * into v_charge;
  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_charge_added',
    jsonb_build_object('charge_id', v_charge.id, 'name', v_charge.name,
      'charge_type', v_charge.charge_type, 'amount', v_charge.amount,
      'tax_amount', v_charge.tax_amount, 'total_amount', v_charge.total_amount));
  return v_charge;
end;
$$;

revoke all on function public.admin_add_rental_charge(uuid, text, text, numeric, boolean, text) from public;
grant execute on function public.admin_add_rental_charge(uuid, text, text, numeric, boolean, text) to authenticated;

create or replace function public.admin_waive_rental_charge(p_charge_id uuid)
returns public.rental_charge_items
language plpgsql security definer set search_path = public
as $$
declare v_charge public.rental_charge_items%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  update public.rental_charge_items set status = 'waived', updated_at = now()
  where id = p_charge_id and not included_in_initial_payment and status in ('pending', 'failed')
  returning * into v_charge;
  if not found then raise exception 'Only an unpaid additional charge can be waived.'; end if;
  return v_charge;
end;
$$;

revoke all on function public.admin_waive_rental_charge(uuid) from public;
grant execute on function public.admin_waive_rental_charge(uuid) to authenticated;

create or replace function public.record_stripe_rental_charge_payment(
  p_charge_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount_total integer,
  p_currency text
) returns public.rental_charge_items
language plpgsql security definer set search_path = public
as $$
declare v_charge public.rental_charge_items%rowtype; v_expected integer;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  select * into v_charge from public.rental_charge_items where id = p_charge_id for update;
  if not found then raise exception 'Rental charge not found.'; end if;
  if v_charge.included_in_initial_payment then raise exception 'Initial booking fees are paid with the rental.'; end if;
  if v_charge.status = 'paid' then return v_charge; end if;
  v_expected := round(v_charge.total_amount * 100)::integer;
  if lower(coalesce(p_currency, 'usd')) <> 'usd' or p_amount_total <> v_expected then
    raise exception 'Stripe payment does not match the rental charge total.';
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
      'checkout_session_id', p_checkout_session_id));
  return v_charge;
end;
$$;

revoke all on function public.record_stripe_rental_charge_payment(uuid, text, text, integer, text) from public;
grant execute on function public.record_stripe_rental_charge_payment(uuid, text, text, integer, text) to service_role;

-- Manual bookings always require the customer to finish verification,
-- documents, agreement, and payment in the client portal.
update public.email_templates
set html_body = '<h1>Your booking is confirmed.</h1><p>Hi {{customer_first_name}},</p><p>We received your payment and confirmed your Rent Me CT reservation.</p><h2>{{vehicle_name}}</h2><p><strong>Booking:</strong> {{booking_number}}<br><strong>Pickup:</strong> {{pickup_date}} at {{pickup_time}}<br><strong>Return:</strong> {{return_date}} at {{return_time}}<br><strong>Rental:</strong> {{rental_total}}<br><strong>Booking fees:</strong> {{service_fee_total}}<br><strong>Tax:</strong> {{tax_amount}}<br><strong>Refundable deposit:</strong> {{deposit_amount}}<br><strong>Total paid:</strong> {{total_paid}}</p><p><a href="{{manage_booking_url}}">Manage your booking</a></p><p>Pickup location: {{business_address}}</p>',
    version = version + 1,
    updated_at = now()
where template_key = 'booking_confirmation';

create or replace function public.queue_booking_confirmation_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype; v_vehicle public.vehicles%rowtype;
begin
  if lower(coalesce(new.payment_status, '')) <> 'paid' or lower(coalesce(old.payment_status, '')) = 'paid' then return new; end if;
  select * into v_template from public.email_templates
    where template_key = 'booking_confirmation' and category = 'automated' and enabled limit 1;
  if not found then return new; end if;
  select * into v_profile from public.profiles where id = new.user_id;
  select * into v_vehicle from public.vehicles where id = new.vehicle_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;
  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'booking_confirmation:' || new.id::text, 'booking_confirmation', v_template.id,
    new.id, new.user_id, lower(trim(v_profile.email)), v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'booking_number', upper(left(replace(new.id::text, '-', ''), 10)),
      'vehicle_name', coalesce(v_vehicle.name, 'Your rental vehicle'),
      'pickup_date', coalesce(to_char(new.pickup_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
      'pickup_time', coalesce(new.pickup_time, 'To be confirmed'),
      'return_date', coalesce(to_char(new.return_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
      'return_time', coalesce(new.return_time, 'To be confirmed'),
      'rental_total', to_char(coalesce(new.rental_total, 0), 'FM$999,999,990.00'),
      'service_fee_total', to_char(coalesce(new.service_fee_total, 0), 'FM$999,999,990.00'),
      'tax_amount', to_char(coalesce(new.tax_amount, 0), 'FM$999,999,990.00'),
      'deposit_amount', to_char(coalesce(new.security_deposit, 0), 'FM$999,999,990.00'),
      'total_paid', to_char(coalesce(new.rental_total, 0) + coalesce(new.service_fee_total, 0) + coalesce(new.tax_amount, 0) + coalesce(new.security_deposit, 0), 'FM$999,999,990.00'),
      'manage_booking_url', 'https://login.rentmect.com',
      'business_address', '12 Holmes Circle, Farmington, CT'
    )
  ) on conflict (event_key) do nothing;
  return new;
end;
$$;

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'admin_booking_action_required', 'Admin Booking — Customer Action Required',
  'automated', 'rental.admin_created',
  'Complete your Rent Me CT booking — {{vehicle_name}}',
  'Verify your identity, upload documents, sign, and pay to finish your reservation.',
  '<h1>Your reservation is waiting for you.</h1><p>Hi {{customer_first_name}},</p><p>Rent Me CT created a reservation for {{vehicle_name}} from {{pickup_date}} at {{pickup_time}} through {{return_date}} at {{return_time}}.</p><p>You must verify your phone and identity, upload your license and insurance, sign the rental agreement, and pay before pickup.</p><p><a href="{{manage_booking_url}}">Complete your booking</a></p>',
  'Rent Me CT created your reservation for {{vehicle_name}}. Complete identity, documents, agreement, and payment here: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set enabled = true;

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'additional_charge_due', 'Additional Rental Charge Due', 'automated',
  'rental.charge_added', 'Additional Rent Me CT charge — {{charge_name}}',
  'Review and securely pay the charge in your client portal.',
  '<h1>An additional rental charge was added.</h1><p>Hi {{customer_first_name}},</p><p><strong>{{charge_name}}</strong>: {{charge_total}}</p><p>{{charge_description}}</p><p><a href="{{manage_booking_url}}">Review and pay securely</a></p>',
  'Additional rental charge: {{charge_name}} — {{charge_total}}. Review and pay securely: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set enabled = true;

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'extension_payment_due', 'Rental Extension — Payment Required', 'automated',
  'rental.extension_approved', 'Your Rent Me CT extension was approved',
  'Pay the additional amount to activate your new return time.',
  '<h1>Your extension was approved.</h1><p>Hi {{customer_first_name}},</p><p>Your request for {{vehicle_name}} through {{requested_return_date}} at {{requested_return_time}} was approved.</p><p><strong>Amount due:</strong> {{extension_total}}</p><p>The new return time is held for you, but the extension does not activate until payment is complete.</p><p><a href="{{manage_booking_url}}">Pay for your extension</a></p>',
  'Your {{vehicle_name}} extension through {{requested_return_date}} at {{requested_return_time}} was approved. Pay {{extension_total}} to activate it: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set enabled = true;

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'additional_charge_paid', 'Additional Rental Charge — Payment Receipt', 'automated',
  'rental.charge_paid', 'Rent Me CT payment received — {{charge_name}}',
  'Your additional rental charge was paid successfully.',
  '<h1>Payment received.</h1><p>Hi {{customer_first_name}},</p><p>We received your payment for <strong>{{charge_name}}</strong>.</p><p><strong>Total paid:</strong> {{charge_total}}</p><p><a href="{{manage_booking_url}}">View your booking</a></p>',
  'Payment received for {{charge_name}}: {{charge_total}}. View your booking: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set enabled = true;

create or replace function public.queue_admin_booking_action_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype; v_vehicle public.vehicles%rowtype;
begin
  if position('Created manually in the admin portal' in coalesce(new.admin_notes, '')) = 0 then return new; end if;
  select * into v_template from public.email_templates where template_key = 'admin_booking_action_required' and enabled limit 1;
  if not found then return new; end if;
  select * into v_profile from public.profiles where id = new.user_id;
  select * into v_vehicle from public.vehicles where id = new.vehicle_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;
  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'admin_booking_action_required:' || new.id::text,
    'admin_booking_action_required', v_template.id, new.id, new.user_id,
    lower(trim(v_profile.email)), v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'vehicle_name', coalesce(v_vehicle.name, 'your rental vehicle'),
      'pickup_date', to_char(new.pickup_date, 'Mon FMDD, YYYY'),
      'pickup_time', new.pickup_time,
      'return_date', to_char(new.return_date, 'Mon FMDD, YYYY'),
      'return_time', new.return_time,
      'manage_booking_url', 'https://login.rentmect.com'
    )
  ) on conflict (event_key) do nothing;
  return new;
end;
$$;

drop trigger if exists rentals_queue_admin_booking_action_email on public.rentals;
create trigger rentals_queue_admin_booking_action_email
after insert on public.rentals for each row execute function public.queue_admin_booking_action_email();

create or replace function public.queue_additional_charge_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype;
begin
  if new.included_in_initial_payment then return new; end if;
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

drop trigger if exists rental_charges_queue_customer_email on public.rental_charge_items;
create trigger rental_charges_queue_customer_email
after insert on public.rental_charge_items
for each row execute function public.queue_additional_charge_email();

create or replace function public.queue_additional_charge_paid_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_template public.email_templates%rowtype; v_profile public.profiles%rowtype;
begin
  if new.included_in_initial_payment or new.status <> 'paid' or old.status is not distinct from new.status then return new; end if;
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

drop trigger if exists rental_charges_queue_paid_email on public.rental_charge_items;
create trigger rental_charges_queue_paid_email
after update of status on public.rental_charge_items
for each row execute function public.queue_additional_charge_paid_email();

-- Extend Pushover to cover extension requests and approvals.
alter table public.admin_notification_events drop constraint if exists admin_notification_events_event_type_check;
alter table public.admin_notification_events add constraint admin_notification_events_event_type_check
  check (event_type in ('new_booking', 'document_pending_review', 'return_due_today',
    'maintenance_due', 'extension_requested', 'extension_approved'));

create or replace function public.queue_extension_admin_notification()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.admin_notification_events (event_type, source_id, rental_id, dedupe_key)
    values ('extension_requested', new.id, new.rental_id, 'extension_requested:' || new.id::text)
    on conflict (dedupe_key) do nothing;
  elsif new.status = 'approved_pending_payment' and old.status is distinct from new.status then
    insert into public.admin_notification_events (event_type, source_id, rental_id, dedupe_key)
    values ('extension_approved', new.id, new.rental_id, 'extension_approved:' || new.id::text)
    on conflict (dedupe_key) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists rental_extensions_queue_admin_notification on public.rental_extension_requests;
create trigger rental_extensions_queue_admin_notification
after insert or update of status on public.rental_extension_requests
for each row execute function public.queue_extension_admin_notification();

create or replace function public.queue_extension_payment_email()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_template public.email_templates%rowtype;
  v_profile public.profiles%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_rental public.rentals%rowtype;
begin
  if new.status <> 'approved_pending_payment' or old.status is not distinct from new.status then
    return new;
  end if;
  select * into v_template from public.email_templates
    where template_key = 'extension_payment_due' and enabled limit 1;
  if not found then return new; end if;
  select * into v_profile from public.profiles where id = new.user_id;
  select * into v_rental from public.rentals where id = new.rental_id;
  select * into v_vehicle from public.vehicles
    where id = coalesce(new.replacement_vehicle_id, v_rental.vehicle_id);
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;
  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'extension_payment_due:' || new.id::text, 'extension_payment_due',
    v_template.id, new.rental_id, new.user_id, lower(trim(v_profile.email)),
    v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'vehicle_name', coalesce(v_vehicle.name, 'your rental vehicle'),
      'requested_return_date', to_char(new.requested_return_date, 'Mon FMDD, YYYY'),
      'requested_return_time', new.requested_return_time,
      'extension_total', to_char(coalesce(new.extension_total_amount, 0), 'FM$999,999,990.00'),
      'manage_booking_url', 'https://login.rentmect.com/?billing=1'
    )
  ) on conflict (event_key) do nothing;
  return new;
end;
$$;

drop trigger if exists rental_extensions_queue_payment_email on public.rental_extension_requests;
create trigger rental_extensions_queue_payment_email
after update of status on public.rental_extension_requests
for each row execute function public.queue_extension_payment_email();

-- An approved extension immediately appears on the admin calendar and reserves
-- the requested window. Payment activation swaps this hold for the real rental
-- date update inside the same transaction.
create or replace function public.sync_extension_calendar_hold()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_vehicle_id uuid;
  v_start_at timestamp;
  v_end_at timestamp;
  v_marker text := '[EXTENSION_REQUEST=' || new.id::text || ']';
begin
  if new.status = 'approved_pending_payment' and old.status is distinct from new.status then
    select * into v_rental from public.rentals where id = new.rental_id;
    if not found then return new; end if;
    v_vehicle_id := case when new.request_kind = 'switch_car_continuation'
      then new.replacement_vehicle_id else v_rental.vehicle_id end;
    v_start_at := public.rentmect_rental_timestamp(
      coalesce(new.original_return_date, v_rental.return_date),
      coalesce(new.original_return_time, v_rental.return_time)
    );
    v_end_at := public.rentmect_rental_timestamp(new.requested_return_date, new.requested_return_time) + interval '3 hours';
    if not exists (select 1 from public.vehicle_availability_blocks where notes like '%' || v_marker || '%') then
      insert into public.vehicle_availability_blocks (
        vehicle_id, start_date, end_date, start_time, end_time,
        block_type, label, notes, active, created_by
      ) values (
        v_vehicle_id, v_start_at::date, v_end_at::date,
        to_char(v_start_at, 'FMHH12:MI AM'), to_char(v_end_at, 'FMHH12:MI AM'),
        'extension_hold', 'Extension approved — payment pending', v_marker, true, new.decided_by
      );
    end if;
  elsif new.status in ('activated', 'rejected', 'cancelled') and old.status is distinct from new.status then
    update public.vehicle_availability_blocks
      set active = false, updated_at = now()
      where notes like '%' || v_marker || '%' and active;
  end if;
  return new;
end;
$$;

drop trigger if exists rental_extensions_sync_calendar_hold on public.rental_extension_requests;
create trigger rental_extensions_sync_calendar_hold
after update of status on public.rental_extension_requests
for each row execute function public.sync_extension_calendar_hold();

create or replace function public.release_extension_calendar_hold(p_extension_request_id uuid)
returns void language sql security definer set search_path = public
as $$
  update public.vehicle_availability_blocks
  set active = false, updated_at = now()
  where notes like '%[EXTENSION_REQUEST=' || p_extension_request_id::text || ']%' and active;
$$;

revoke all on function public.release_extension_calendar_hold(uuid) from public;
grant execute on function public.release_extension_calendar_hold(uuid) to authenticated, service_role;

create or replace function public.cancel_admin_approved_extension(p_extension_request_id uuid)
returns public.rental_extension_requests
language plpgsql security definer set search_path = public
as $$
declare v_request public.rental_extension_requests%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  update public.rental_extension_requests
    set status = 'cancelled', payment_status = 'not_due', updated_at = now()
    where id = p_extension_request_id
      and status = 'approved_pending_payment'
      and payment_status = 'pending'
    returning * into v_request;
  if not found then raise exception 'Only an approved unpaid extension can be cancelled.'; end if;
  return v_request;
end;
$$;

revoke all on function public.cancel_admin_approved_extension(uuid) from public;
grant execute on function public.cancel_admin_approved_extension(uuid) to authenticated;
