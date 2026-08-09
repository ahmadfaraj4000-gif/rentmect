import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/20260809013000_internal_admin_fee_templates.sql');
const quoteSource = read('supabase/migrations/20260806022000_out_the_door_booking_quote.sql');
const billingSource = read('supabase/rental_billing_and_completion.sql');
const publicPrice = read('cars-2.html');

const checks = [
  ['public quote returns zero internal fees', /'service_fee_total', 0/.test(migration)],
  ['public quote source no longer reads fee templates', !/from public\.service_fees\s+where active/i.test(quoteSource)],
  ['new rental pricing clears template totals', /new\.service_fee_total := 0;[\s\S]*new\.taxable_service_fee_total := 0;/.test(billingSource)],
  ['new rentals do not snapshot active templates', !/create trigger rentals_snapshot_service_fees[\s\S]*execute function public\.snapshot_rental_service_fees/i.test(billingSource)],
  ['customer-facing summary excludes active booking fees', !/active booking fees/i.test(publicPrice)],
  ['customer-facing price card has no booking-fee row', !/Booking fees|cars2ServiceFee/i.test(`${publicPrice}\n${read('cars-2.js')}`)],
  ['customer-facing summary explains later admin-applied charges', /Admin-applied rental charges/i.test(publicPrice)],
  ['non-admin active-template read policy is removed', /drop policy if exists "Authenticated users can read active service fees"/.test(migration)],
  ['unpaid leaked fee totals are repaired', /update public\.rentals[\s\S]*service_fee_total = 0[\s\S]*payment_status/.test(migration)],
];

const failed = checks.filter(([, passed]) => !passed);
for (const [name, passed] of checks) console.log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
if (failed.length) process.exitCode = 1;
