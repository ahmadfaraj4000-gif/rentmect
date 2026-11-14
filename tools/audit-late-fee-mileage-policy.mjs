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

check('public policy has no legacy 200-mile allowance', !/200\s+miles|200\s+miles\/day/i.test(publicPolicy));
check('public policy publishes the 250-mile allowance', /250\s+miles/i.test(publicPolicy));
check('homepage daily-mileage stat displays 250', /<strong>250<\/strong>\s*<span>Miles Included Daily<\/span>/.test(read('index.html')));
check('public agreement requires explicit approval instead of automatic fees', /no automatic late-return fee or automatic additional rental-day charge/.test(read('agreement.html')));
const returnPolicy = read('supabase/migrations/20261114030000_admin_return_availability.sql');
check('backend disables automatic assessment', returnPolicy.includes('select 0;') && returnPolicy.includes('aaaa_no_automatic_late_charge'));
check('backend protects physical returns', returnPolicy.includes('aaaa_physical_return_transition'));

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exitCode = 1;
} else {
  console.log('Late-return and mileage policy audit passed.');
}
