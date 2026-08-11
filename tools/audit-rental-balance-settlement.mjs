import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260811120000_partial_rental_balance_settlement.sql', import.meta.url),
  'utf8',
);
const stripeFunction = readFileSync(
  new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url),
  'utf8',
);

assert.match(migration, /rentmect_rental_net_paid_amount/);
assert.match(migration, /sync_rental_remaining_balance/);
assert.match(migration, /'partially_paid'/);
assert.match(migration, /'Remaining rental balance'/);
assert.match(migration, /record_admin_rental_balance_payment/);
assert.match(migration, /external_payment_method/);
assert.match(migration, /v_discount := case[\s\S]*else v_value/);
assert.match(migration, /v_new_rental := round\(v_base_rental - v_discount/);
assert.match(migration, /manual_discount_tax_savings/);
assert.match(migration, /charge_type = 'rental_amendment'/);
assert.match(migration, /status in \('processing', 'pending', 'succeeded'\)/);
assert.match(migration, /extension_request_id is null/);
assert.doesNotMatch(migration, /grant execute on function public\.sync_rental_remaining_balance\(uuid,uuid\)[\s\S]{0,80}to authenticated/);

assert.match(stripeFunction, /admin_record_external_balance/);
assert.match(stripeFunction, /Sign the revised rental agreement/);
assert.match(stripeFunction, /charge_type", "rental_amendment"/);
assert.match(stripeFunction, /expectedAmountCents|amountCents,/);
assert.match(stripeFunction, /checkout\.sessions\.expire/);

console.log('Partial rental balance settlement audit passed.');
