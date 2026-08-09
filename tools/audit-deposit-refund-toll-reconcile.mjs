import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260809152500_reconcile_paid_tolls_for_deposit_release.sql', import.meta.url),
  'utf8',
);

assert.match(migration, /rental_charge_item_id = charge\.id/);
assert.match(migration, /charge\.source_reference = toll\.tollspot_transaction_id/);
assert.match(migration, /v_charge_status = 'paid'[\s\S]*new\.status := 'paid'/);
assert.match(migration, /v_charge_status = 'waived'[\s\S]*new\.status := 'ignored'/);
assert.match(migration, /and not exists \([\s\S]*charge\.status[\s\S]*in \('paid', 'waived'\)/);
assert.match(migration, /charge\.status in \('pending', 'checkout_open', 'failed'\)/);
assert.match(migration, /report\.status[\s\S]*not in \('resolved', 'closed', 'completed'\)/);

console.log('Deposit-refund TollSpot reconciliation audit passed.');
