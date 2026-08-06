import { readFile } from 'node:fs/promises';

const migration = await readFile(
  new URL('../supabase/migrations/20260806120000_return_reminders_via_email.sql', import.meta.url),
  'utf8',
);
const worker = await readFile(
  new URL('../supabase/functions/send-emails/index.ts', import.meta.url),
  'utf8',
);
const smsBootstrap = await readFile(
  new URL('../supabase/rental_due_sms_reminders.sql', import.meta.url),
  'utf8',
);
const processRoute = worker.slice(worker.indexOf('if (pathname.endsWith("/process"))'));

const checks = [
  ['Day-before return email is configured', migration.includes("'return_due_previous_morning_email'")],
  ['Three-hour return email is configured', migration.includes("'return_due_3h_email'")],
  ['Overdue return email is configured', migration.includes("'return_overdue_3h_email'")],
  ['Quiet hours remain 8 AM through 9 PM ET', migration.includes("time '08:00'") && migration.includes("time '21:00'")],
  ['Transactional email does not require marketing opt-in', !migration.includes('email_marketing_opt_in')],
  ['Return emails use an idempotent outbox key', migration.includes("'return_reminder_email:'") && migration.includes('on conflict (event_key)')],
  ['Stale retryable reminders are cancelled', migration.includes("outbox.status in ('pending', 'failed')") && migration.includes("status = 'cancelled'")],
  ['Email removal or change cancels stale reminders', migration.includes("outbox.recipient_email is distinct from lower(trim(profile.email))")],
  ['Email worker queues return reminders before processing', processRoute.indexOf('queueReturnReminderEmails()') < processRoute.indexOf('processOutbox()')],
  ['Automated customer return SMS claim is disabled', migration.includes('This function intentionally returns no rows') && migration.includes('where false;')],
  ['Database bootstrap also keeps return SMS disabled', smsBootstrap.includes('rebuilding the database cannot silently re-enable it') && smsBootstrap.includes('where false;')],
];

for (const [label, passed] of checks) {
  console.log(`${passed ? 'PASS' : 'FAIL'} ${label}`);
}

const failures = checks.filter(([, passed]) => !passed);
if (failures.length) process.exitCode = 1;
else console.log(`\nAll ${checks.length} return-reminder email checks passed.`);
