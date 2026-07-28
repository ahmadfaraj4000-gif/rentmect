-- Rent Me CT transactional and broadcast email system.
-- Run after profiles, vehicles, rentals, and public.is_admin() exist.

create extension if not exists pgcrypto;

create table if not exists public.email_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique,
  name text not null,
  category text not null default 'manual' check (category in ('automated', 'manual')),
  trigger_key text,
  subject text not null,
  preheader text,
  html_body text not null,
  text_body text,
  enabled boolean not null default true,
  version integer not null default 1,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.email_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  template_id uuid references public.email_templates(id) on delete set null,
  subject text not null,
  preheader text,
  html_body text not null,
  text_body text,
  audience_type text not null default 'marketing_opted_in'
    check (audience_type in ('marketing_opted_in', 'active_rentals', 'upcoming_pickups', 'past_customers', 'selected')),
  selected_user_ids uuid[] not null default '{}',
  status text not null default 'draft'
    check (status in ('draft', 'scheduled', 'sending', 'completed', 'failed', 'cancelled')),
  scheduled_for timestamptz,
  recipient_count integer not null default 0,
  sent_count integer not null default 0,
  failed_count integer not null default 0,
  last_error text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.email_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.email_campaigns(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text not null,
  customer_name text,
  status text not null default 'pending'
    check (status in ('pending', 'processed', 'delivered', 'deferred', 'bounced', 'spam', 'unsubscribed', 'failed')),
  provider_message_id text,
  error text,
  processed_at timestamptz,
  delivered_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (campaign_id, email)
);

create table if not exists public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  email_type text not null,
  template_id uuid references public.email_templates(id) on delete set null,
  rental_id uuid references public.rentals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  recipient_email text not null,
  recipient_name text,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed', 'cancelled')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.email_delivery_events (
  id uuid primary key default gen_random_uuid(),
  provider_event_id text unique,
  provider_message_id text,
  email text,
  event_type text not null,
  event_at timestamptz not null default now(),
  campaign_id uuid references public.email_campaigns(id) on delete set null,
  outbox_id uuid references public.email_outbox(id) on delete set null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add column if not exists email_marketing_opt_in boolean not null default false,
  add column if not exists email_marketing_opted_in_at timestamptz,
  add column if not exists email_marketing_unsubscribed_at timestamptz;

create or replace function public.set_email_marketing_preference(p_opt_in boolean)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  update public.profiles
  set
    email_marketing_opt_in = coalesce(p_opt_in, false),
    email_marketing_opted_in_at = case when coalesce(p_opt_in, false) then now() else email_marketing_opted_in_at end,
    email_marketing_unsubscribed_at = case when coalesce(p_opt_in, false) then null else now() end
  where id = auth.uid()
  returning * into v_profile;

  if not found then
    raise exception 'Customer profile not found';
  end if;

  return v_profile;
end;
$$;

revoke all on function public.set_email_marketing_preference(boolean) from public;
grant execute on function public.set_email_marketing_preference(boolean) to authenticated;

create index if not exists email_outbox_pending_idx
  on public.email_outbox (status, next_attempt_at);
create index if not exists email_campaigns_scheduled_idx
  on public.email_campaigns (status, scheduled_for);
create index if not exists email_delivery_events_message_idx
  on public.email_delivery_events (provider_message_id, event_at desc);

create or replace function public.set_email_record_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_email_templates_updated_at on public.email_templates;
create trigger set_email_templates_updated_at
before update on public.email_templates
for each row execute function public.set_email_record_updated_at();

drop trigger if exists set_email_campaigns_updated_at on public.email_campaigns;
create trigger set_email_campaigns_updated_at
before update on public.email_campaigns
for each row execute function public.set_email_record_updated_at();

drop trigger if exists set_email_campaign_recipients_updated_at on public.email_campaign_recipients;
create trigger set_email_campaign_recipients_updated_at
before update on public.email_campaign_recipients
for each row execute function public.set_email_record_updated_at();

drop trigger if exists set_email_outbox_updated_at on public.email_outbox;
create trigger set_email_outbox_updated_at
before update on public.email_outbox
for each row execute function public.set_email_record_updated_at();

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'booking_confirmation',
  'Booking Confirmation',
  'automated',
  'rental.payment_paid',
  'Your Rent Me CT booking is confirmed — {{vehicle_name}}',
  'Your vehicle, schedule, payment, and pickup details are inside.',
  '<h1>Your booking is confirmed.</h1><p>Hi {{customer_first_name}},</p><p>We received your payment and confirmed your Rent Me CT reservation.</p><h2>{{vehicle_name}}</h2><p><strong>Booking:</strong> {{booking_number}}<br><strong>Pickup:</strong> {{pickup_date}} at {{pickup_time}}<br><strong>Return:</strong> {{return_date}} at {{return_time}}<br><strong>Rental:</strong> {{rental_total}}<br><strong>Tax:</strong> {{tax_amount}}<br><strong>Refundable deposit:</strong> {{deposit_amount}}</p><p><a href="{{manage_booking_url}}">Manage your booking</a></p><p>Pickup location: {{business_address}}</p>',
  'Your booking is confirmed. Vehicle: {{vehicle_name}}. Booking: {{booking_number}}. Pickup: {{pickup_date}} at {{pickup_time}}. Return: {{return_date}} at {{return_time}}. Manage your booking: {{manage_booking_url}}',
  true
), (
  'general_announcement',
  'General Customer Announcement',
  'manual',
  null,
  'An update from Rent Me CT',
  'Important information from Rent Me CT.',
  '<h1>An update from Rent Me CT</h1><p>Hi {{customer_first_name}},</p><p>Add your message here.</p>',
  'Hi {{customer_first_name}}, Add your message here.',
  true
)
on conflict (template_key) do nothing;

create or replace function public.queue_booking_confirmation_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template public.email_templates%rowtype;
  v_profile public.profiles%rowtype;
  v_vehicle public.vehicles%rowtype;
begin
  if lower(coalesce(new.payment_status, '')) <> 'paid'
     or lower(coalesce(old.payment_status, '')) = 'paid' then
    return new;
  end if;

  select * into v_template
  from public.email_templates
  where template_key = 'booking_confirmation'
    and category = 'automated'
    and enabled
  limit 1;

  if not found then return new; end if;

  select * into v_profile from public.profiles where id = new.user_id;
  select * into v_vehicle from public.vehicles where id = new.vehicle_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;

  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'booking_confirmation:' || new.id::text,
    'booking_confirmation',
    v_template.id,
    new.id,
    new.user_id,
    lower(trim(v_profile.email)),
    v_profile.full_name,
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
      'tax_amount', to_char(coalesce(new.tax_amount, 0), 'FM$999,999,990.00'),
      'deposit_amount', to_char(coalesce(new.security_deposit, 0), 'FM$999,999,990.00'),
      'manage_booking_url', 'https://login.rentmect.com',
      'business_address', '12 Holmes Circle, Farmington, CT'
    )
  ) on conflict (event_key) do nothing;

  return new;
end;
$$;

drop trigger if exists queue_booking_confirmation_email_on_payment on public.rentals;
create trigger queue_booking_confirmation_email_on_payment
after update of payment_status on public.rentals
for each row execute function public.queue_booking_confirmation_email();

alter table public.email_templates enable row level security;
alter table public.email_campaigns enable row level security;
alter table public.email_campaign_recipients enable row level security;
alter table public.email_outbox enable row level security;
alter table public.email_delivery_events enable row level security;

drop policy if exists "Admins manage email templates" on public.email_templates;
create policy "Admins manage email templates" on public.email_templates
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins manage email campaigns" on public.email_campaigns;
create policy "Admins manage email campaigns" on public.email_campaigns
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins read email campaign recipients" on public.email_campaign_recipients;
create policy "Admins read email campaign recipients" on public.email_campaign_recipients
for select to authenticated using (public.is_admin());

drop policy if exists "Admins read email outbox" on public.email_outbox;
create policy "Admins read email outbox" on public.email_outbox
for select to authenticated using (public.is_admin());

drop policy if exists "Admins read email delivery events" on public.email_delivery_events;
create policy "Admins read email delivery events" on public.email_delivery_events
for select to authenticated using (public.is_admin());

revoke all on public.email_templates, public.email_campaigns, public.email_campaign_recipients, public.email_outbox, public.email_delivery_events from anon;
grant select, insert, update, delete on public.email_templates, public.email_campaigns to authenticated;
grant select on public.email_campaign_recipients, public.email_outbox, public.email_delivery_events to authenticated;
