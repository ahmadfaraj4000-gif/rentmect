import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260810130000_admin_manual_rental_discounts.sql', import.meta.url),
  'utf8',
);
const stripeFunction = readFileSync(
  new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url),
  'utf8',
);

assert.match(migration, /admin_preview_manual_rental_discount/);
assert.match(migration, /admin_apply_manual_rental_discount/);
assert.match(migration, /manual_discount_amount/);
assert.match(migration, /manual_discount_type/);
assert.match(migration, /manual_discount_value/);
assert.match(migration, /v_mode not in \('fixed', 'percentage', 'remove'\)/);
assert.doesNotMatch(migration, /target_total|desired final total/i);
assert.match(migration, /v_deposit := round\(coalesce\(v_rental\.security_deposit/);
assert.match(migration, /'deposit_unchanged', true/);
assert.match(migration, /customer_credit_due/);
assert.match(migration, /payment_amount_cents = case[\s\S]*payment_status[\s\S]*<> 'paid'/);
assert.match(migration, /admin_preview_rental_amendment_without_manual_discount/);
assert.doesNotMatch(migration, /update public\.vehicles/);

assert.match(stripeFunction, /admin_apply_manual_discount/);
assert.match(stripeFunction, /checkout\.sessions\.expire/);
assert.match(stripeFunction, /manual_discount_amount/);

console.log('Manual rental discount audit passed.');
