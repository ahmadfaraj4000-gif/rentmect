import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const failures = [];
const check = (label, condition) => {
  if (!condition) failures.push(label);
};

const publicPolicyFiles = [
  'agreement.html',
  'index.html',
  'requirements.html',
  'weekly-car-rental-ct.html',
  'car-rental-farmington-ct.html',
  'luxury-car-rental-connecticut.html',
  'script.js',
  'llms.txt',
];
const publicPolicy = publicPolicyFiles.map(read).join('\n');
const migration = read('supabase/migrations/20260808233000_late_fee_and_250_mileage_policy.sql');

check('public policy has no legacy 200-mile allowance', !/200\s+miles|200\s+miles\/day/i.test(publicPolicy));
check('public policy publishes the 250-mile allowance', /250\s+miles/i.test(publicPolicy));
check('public agreement publishes the 30-minute fee', /At 30 minutes after the scheduled return time/.test(read('agreement.html')));
check('public agreement publishes the more-than-two-hour daily charge', /more than 2 hours after the scheduled return time/.test(read('agreement.html')));
check('backend stages the fee at 30 minutes', /p_as_of >= late_rentals\.due_at \+ interval '30 minutes'/.test(migration));
check('backend stages the daily charge strictly after two hours', /p_as_of > late_rentals\.due_at \+ interval '2 hours'/.test(migration));
check('backend uses separate idempotency references', migration.includes("|| ':late-fee'") && migration.includes("|| ':period:'"));
check('backend never attempts payment', /Payment requires administrator action/.test(migration) && /'payment_attempted', false/.test(migration));
check('backend preserves the three-hour physical lock', read('supabase/migrations/20260804023000_stage_late_return_charges.sql').includes("+ interval '3 hours'"));

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Late-return and mileage policy audit passed.');
}
