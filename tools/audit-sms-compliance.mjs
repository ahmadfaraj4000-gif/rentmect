import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');

const client = read('rentmect-client-portal/src/main.jsx');
const clientCss = read('rentmect-client-portal/src/final-overrides.css');
const privacy = read('privacy-policy.html');
const terms = read('terms.html');
const migration = read('supabase/migrations/20260726090000_sms_consent_compliance.sql');
const templateMigration = read('supabase/migrations/20260726180000_sms_template_campaign_compliance.sql');
const reminderWorker = read('supabase/functions/send-rental-due-reminders/index.ts');
const admin = read('rentmect-admin-portal/src/main.jsx');

const checks = [
  ['Recurring SMS checkbox is present', client.includes('function SmsTransactionalPreference')],
  ['SMS checkbox is unchecked by default', client.includes('sms_transactional_opt_in: false')],
  ['All phone edits clear stale consent', (client.match(/phone: .*sms_transactional_opt_in: false/g) || []).length >= 3],
  ['Verification text disclosure is present', client.includes('function SmsVerificationDisclosure')],
  ['SMS disclosure links to public terms', client.includes('terms.html#sms-terms')],
  ['SMS disclosure links to public privacy policy', client.includes('privacy-policy.html#sms-privacy')],
  ['SMS consent control has mobile styling', clientCss.includes('.sms-consent-preference')],
  ['Privacy policy has an SMS section', privacy.includes('id="sms-privacy"')],
  ['Privacy policy prohibits marketing sharing', privacy.includes('does not sell or share mobile phone information or SMS opt-in data and consent')],
  ['Terms have an SMS program section', terms.includes('id="sms-terms"')],
  ['Terms disclose variable frequency and carrier rates', terms.includes('Message frequency varies') && terms.includes('Message and data rates may apply')],
  ['Terms disclose STOP and HELP', terms.includes('<strong>STOP</strong>') && terms.includes('<strong>HELP</strong>')],
  ['Terms include carrier delivery disclaimer', terms.includes('Wireless carriers are not liable for delayed or undelivered messages')],
  ['Database stores current SMS consent', migration.includes('sms_transactional_opt_in boolean not null default false')],
  ['Database records immutable consent events', migration.includes('create table if not exists public.sms_consent_events')],
  ['Phone changes clear previous consent', migration.includes('profiles_clear_sms_consent_on_phone_change')],
  ['Automated reminders require active consent', migration.includes('coalesce(profiles.sms_transactional_opt_in, false)')],
  ['SMS worker rechecks consent before sending', reminderWorker.includes('Customer transactional SMS consent is not active.')],
  ['Customer messages contain STOP/HELP instructions', reminderWorker.includes('Reply STOP to unsubscribe or HELP for help.')],
  ['SMS send path always identifies Rent Me CT', reminderWorker.includes('if (!/\\bRent Me CT\\b/i.test(body))')],
  ['SMS send path enforces the campaign message limit', reminderWorker.includes('body.length > 1024')],
  ['Admin editor requires brand, STOP, and HELP', admin.includes('smsTemplateComplianceError') && admin.includes('SMS_COMPLIANCE_FOOTER')],
  ['Database normalizes older admin templates', templateMigration.includes('Normalize any administrator-created templates')],
  ['Database prevents noncompliant templates', templateMigration.includes('sms_templates_identify_rentmect') && templateMigration.includes('sms_templates_include_stop') && templateMigration.includes('sms_templates_include_help')],
  ['Approved campaign samples are canonical templates', templateMigration.includes('Payment is required to complete your booking') && templateMigration.includes('We still need your license and insurance documents') && templateMigration.includes('Your {{vehicle_name}} is ready for pickup')],
];

let failed = 0;
for (const [label, passed] of checks) {
  console.log(`${passed ? 'PASS' : 'FAIL'} ${label}`);
  if (!passed) failed += 1;
}

if (failed) {
  console.error(`\n${failed} SMS compliance check${failed === 1 ? '' : 's'} failed.`);
  process.exit(1);
}

console.log(`\nAll ${checks.length} SMS compliance checks passed.`);
