import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const start = source.indexOf('async function releaseSecurityDeposit(');
const end = source.indexOf('// A temporary administrator Stripe installment', start);
const code = stripTypeScriptTypes(source.slice(start, end) + '\nreturn "passed deadline guard";\n}');
function release(dueAt, source = 'automatic') {
  const rental = { id: 'rental', status: 'completed', deposit_status: 'held', deposit_release_due_at: dueAt };
  const context = vm.createContext({ adminClient: { from() { return { select() { return this; }, eq() { return this; }, single: async () => ({ data: rental, error: null }) }; } } });
  vm.runInContext(code, context);
  return context.releaseSecurityDeposit('rental', source);
}
for (const deadline of [null, '', 'invalid', '2099-01-01T00:00:00Z']) test(`automatic refund rejects missing or future deadline: ${deadline}`, async () => {
  await assert.rejects(release(deadline), /not due for automatic refund/);
});
test('automatic refund proceeds to the existing financial checks when due', async () => {
  assert.equal(await release('2020-01-01T00:00:00Z'), 'passed deadline guard');
});
test('admin early refund bypasses the timer and still proceeds to existing financial checks', async () => {
  assert.equal(await release('2099-01-01T00:00:00Z', 'manual'), 'passed deadline guard');
});
