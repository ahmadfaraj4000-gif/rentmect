-- Admin-controlled one-to-one email and SMS templates with delivery logging.
-- Run after email_automation_and_campaigns.sql and rental_due_sms_reminders.sql.

create table if not exists public.sms_templates (
  id uuid primary key default gen_random_uuid(),
  template_key text not null unique,
  name text not null,
  category text not null default 'manual' check (category in ('automated', 'manual')),
  body text not null,
  enabled boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_customer_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rental_id uuid references public.rentals(id) on delete set null,
  channel text not null check (channel in ('email', 'sms')),
  email_template_id uuid references public.email_templates(id) on delete set null,
  sms_template_id uuid references public.sms_templates(id) on delete set null,
  recipient text not null,
  subject text,
  rendered_body text not null,
  status text not null check (status in ('sent', 'failed')),
  provider_message_id text,
  last_error text,
  created_by uuid references auth.users(id) on delete set null,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.sms_templates enable row level security;
alter table public.admin_customer_messages enable row level security;

drop policy if exists "Admins manage SMS templates" on public.sms_templates;
create policy "Admins manage SMS templates" on public.sms_templates
for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins read customer message history" on public.admin_customer_messages;
create policy "Admins read customer message history" on public.admin_customer_messages
for select to authenticated using (public.is_admin());

grant select, insert, update on public.sms_templates to authenticated;
grant select on public.admin_customer_messages to authenticated;

insert into public.sms_templates (template_key, name, category, body) values
  ('manual_return_due_warning', 'Return Due — Fee Warning', 'manual',
   'Rent Me CT: {{vehicle_name}} is due back on {{return_date}} at {{return_time}} ET. Late return may result in additional rental, recovery, and administrative fees. Questions? Call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_return_due_3h', 'Return Due in 3 Hours', 'manual',
   'Rent Me CT: {{vehicle_name}} is due back in about 3 hours at {{return_time}} ET. If you expect a delay, call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_overdue', 'Vehicle Overdue — Immediate Action', 'manual',
   'Rent Me CT: {{vehicle_name}} is overdue. Additional rental, late, recovery, and related fees may continue to accrue. Call {{business_phone}} now. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_payment_due', 'Booking Payment Required', 'manual',
   'Rent Me CT: Payment is required to complete your booking for {{vehicle_name}}. Pay securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_additional_charge_due', 'Additional Charge — Payment Link', 'manual',
   'Rent Me CT: An additional rental charge of {{charge_total}} was added for {{charge_name}}. Review and pay at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_extension_payment_due', 'Extension Payment Required', 'manual',
   'Rent Me CT: Your rental extension was approved but is not active until payment is completed. Pay securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_documents_missing', 'Documents Required', 'manual',
   'Rent Me CT: We still need your license and insurance documents before pickup. Upload them securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_identity_required', 'Identity Verification Required', 'manual',
   'Rent Me CT: Please complete identity verification for your booking before pickup at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_pickup_ready', 'Vehicle Ready for Pickup', 'manual',
   'Rent Me CT: Your {{vehicle_name}} is ready for pickup on {{pickup_date}} at {{pickup_time}} ET. Questions? Call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'),
  ('manual_general_followup', 'General Customer Follow-up', 'manual',
   'Rent Me CT: We are following up about your rental. Please call {{business_phone}} when convenient. Reply STOP to unsubscribe or HELP for help.')
on conflict (template_key) do update set
  name = excluded.name, body = excluded.body, enabled = true,
  version = public.sms_templates.version + 1, updated_at = now();

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values
  ('manual_return_due_warning', 'Return Due — Fee Warning', 'manual', null,
   'Important return reminder for {{vehicle_name}}', 'Your rental return time is approaching.',
   '<h1>Rental return reminder</h1><p>Hi {{customer_first_name}},</p><p><strong>{{vehicle_name}}</strong> is due {{return_date}} at {{return_time}} ET.</p><p>Late return may result in additional rental, recovery, and administrative fees. Contact us immediately if you expect a delay.</p><p><a href="{{manage_booking_url}}">View your booking</a></p>',
   '{{vehicle_name}} is due {{return_date}} at {{return_time}} ET. Late return may result in additional fees. {{manage_booking_url}}', true),
  ('manual_payment_due', 'Booking Payment Required', 'manual', null,
   'Payment required to complete your Rent Me CT booking', 'Complete your secure payment.',
   '<h1>Payment is required</h1><p>Hi {{customer_first_name}},</p><p>Your booking for <strong>{{vehicle_name}}</strong> is waiting for payment.</p><p><a href="{{manage_booking_url}}">Complete payment securely</a></p>',
   'Payment is required for {{vehicle_name}}. Complete it securely: {{manage_booking_url}}', true),
  ('manual_additional_charge_due', 'Additional Charge — Payment Link', 'manual', null,
   'Additional Rent Me CT charge — {{charge_name}}', 'Review and securely pay your additional rental charge.',
   '<h1>An additional rental charge was added</h1><p>Hi {{customer_first_name}},</p><p><strong>{{charge_name}}</strong>: {{charge_total}}</p><p>{{charge_description}}</p><p><a href="{{manage_booking_url}}">Review and pay securely</a></p>',
   'Additional rental charge: {{charge_name}} — {{charge_total}}. Review and pay securely: {{manage_booking_url}}', true),
  ('manual_documents_missing', 'Documents Required', 'manual', null,
   'Documents required for your Rent Me CT booking', 'Upload your license and insurance before pickup.',
   '<h1>Documents are still required</h1><p>Hi {{customer_first_name}},</p><p>Please upload your driver license and insurance documents before pickup.</p><p><a href="{{manage_booking_url}}">Upload documents securely</a></p>',
   'Please upload your license and insurance before pickup: {{manage_booking_url}}', true),
  ('manual_pickup_ready', 'Vehicle Ready for Pickup', 'manual', null,
   '{{vehicle_name}} is ready for pickup', 'Your Rent Me CT vehicle is ready.',
   '<h1>Your vehicle is ready</h1><p>Hi {{customer_first_name}},</p><p><strong>{{vehicle_name}}</strong> is ready for your scheduled pickup on {{pickup_date}} at {{pickup_time}} ET.</p><p><a href="{{manage_booking_url}}">View booking details</a></p>',
   '{{vehicle_name}} is ready for pickup {{pickup_date}} at {{pickup_time}} ET. {{manage_booking_url}}', true)
on conflict (template_key) do update set enabled = true;
