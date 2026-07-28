-- Align every admin SMS template with the registered Rent Me CT campaign:
-- identify the brand, provide STOP/HELP instructions, and keep the approved
-- transactional samples as the canonical built-in templates.

insert into public.sms_templates (template_key, name, category, body) values
  (
    'manual_return_due_warning',
    'Return Due — Fee Warning',
    'manual',
    'Rent Me CT: {{vehicle_name}} is due back on {{return_date}} at {{return_time}} ET. Late return may result in additional rental, recovery, and administrative fees. Questions? Call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_return_due_3h',
    'Return Due in 3 Hours',
    'manual',
    'Rent Me CT: {{vehicle_name}} is due back in about 3 hours at {{return_time}} ET. If you expect a delay, call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_overdue',
    'Vehicle Overdue — Immediate Action',
    'manual',
    'Rent Me CT: {{vehicle_name}} is overdue. Additional rental, late, recovery, and related fees may continue to accrue. Call {{business_phone}} now. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_payment_due',
    'Booking Payment Required',
    'manual',
    'Rent Me CT: Payment is required to complete your booking for {{vehicle_name}}. Pay securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_additional_charge_due',
    'Additional Charge — Payment Link',
    'manual',
    'Rent Me CT: An additional rental charge of {{charge_total}} was added for {{charge_name}}. Review and pay at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_extension_payment_due',
    'Extension Payment Required',
    'manual',
    'Rent Me CT: Your rental extension was approved but is not active until payment is completed. Pay securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_documents_missing',
    'Documents Required',
    'manual',
    'Rent Me CT: We still need your license and insurance documents before pickup. Upload them securely at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_identity_required',
    'Identity Verification Required',
    'manual',
    'Rent Me CT: Please complete identity verification for your booking before pickup at {{manage_booking_url}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_pickup_ready',
    'Vehicle Ready for Pickup',
    'manual',
    'Rent Me CT: Your {{vehicle_name}} is ready for pickup on {{pickup_date}} at {{pickup_time}} ET. Questions? Call {{business_phone}}. Reply STOP to unsubscribe or HELP for help.'
  ),
  (
    'manual_general_followup',
    'General Customer Follow-up',
    'manual',
    'Rent Me CT: We are following up about your rental. Please call {{business_phone}} when convenient. Reply STOP to unsubscribe or HELP for help.'
  )
on conflict (template_key) do update
set
  name = excluded.name,
  category = excluded.category,
  body = excluded.body,
  enabled = true,
  version = public.sms_templates.version + 1,
  updated_at = now();

-- Normalize any administrator-created templates that predate this migration.
update public.sms_templates
set
  body = trim(
    case
      when body ~* '\mRent[[:space:]]+Me[[:space:]]+CT\M' then body
      else 'Rent Me CT: ' || body
    end
    ||
    case
      when body ~* '\mReply[[:space:]]+STOP\M' and body ~* '\mHELP\M' then ''
      else ' Reply STOP to unsubscribe or HELP for help.'
    end
  ),
  version = version + 1,
  updated_at = now()
where
  body !~* '\mRent[[:space:]]+Me[[:space:]]+CT\M'
  or body !~* '\mReply[[:space:]]+STOP\M'
  or body !~* '\mHELP\M';

alter table public.sms_templates
  drop constraint if exists sms_templates_identify_rentmect,
  drop constraint if exists sms_templates_include_stop,
  drop constraint if exists sms_templates_include_help;

alter table public.sms_templates
  add constraint sms_templates_identify_rentmect
    check (body ~* '\mRent[[:space:]]+Me[[:space:]]+CT\M'),
  add constraint sms_templates_include_stop
    check (body ~* '\mReply[[:space:]]+STOP\M'),
  add constraint sms_templates_include_help
    check (body ~* '\mHELP\M');

