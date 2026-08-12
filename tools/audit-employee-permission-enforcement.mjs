import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(
  new URL('../supabase/migrations/20260812020000_enforce_employee_permissions.sql', import.meta.url),
  'utf8',
);

for (const permission of [
  'rental.edit', 'rental.cancel', 'rental.discount', 'rental.return',
  'payment.collect', 'payment.refund', 'deposit.resolve', 'charge.manage',
  'vehicle.manage', 'customer.manage', 'communications.send',
  'communications.templates', 'reports.financial', 'audit.view',
  'override.emergency', 'settings.operational',
]) {
  assert.match(migration, new RegExp(permission.replace('.', '\\.')));
}

assert.match(migration, /enforce_employee_rental_permission/);
assert.match(migration, /enforce_employee_vehicle_permission/);
assert.match(migration, /admin_record_local_deposit_release[\s\S]*?deposit\.resolve/);
assert.match(migration, /Employee financial visibility guard/);
assert.match(migration, /Employee permission guard/);

console.log('Employee permission database enforcement audit passed.');
