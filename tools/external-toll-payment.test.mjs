import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { closeTollCollectionPaths } from '../supabase/functions/_shared/external-toll-payment.js';
const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const edgeCode = stripTypeScriptTypes(source.slice(source.indexOf('async function recordExternalTollPayment('), source.indexOf('async function confirmCheckout(')));
const charges = [{ id: 'one', stripe_checkout_session_id: 'cs_one' }, { id: 'two', stripe_payment_intent_id: 'pi_two' }];
function fixture({ checkout = 'open', intent = 'requires_confirmation', providerFailure = false, posted = false, denied = false } = {}) {
  const calls = [];
  const stripe = {
    checkout: { sessions: {
      retrieve: async id => { calls.push(['retrieveSession', id]); return { id, status: checkout, payment_status: checkout === 'complete' ? 'paid' : 'unpaid', payment_intent: 'pi_one' }; },
      expire: async id => { calls.push(['expire', id]); if (providerFailure) throw Error('Network timeout'); return { id, status: 'expired', payment_intent: 'pi_one' }; },
    } },
    paymentIntents: {
      retrieve: async id => { calls.push(['retrieveIntent', id]); return { id, status: intent }; },
      cancel: async id => { calls.push(['cancelIntent', id]); return { id, status: 'canceled' }; },
    },
  };
  const context = vm.createContext({ HttpError: Error, closeTollCollectionPaths, stripe, requireAdmin: async () => {
    if (denied) throw Error('Permission denied'); return { user: { id: 'admin' } };
  }, adminClient: { rpc: async (name, args) => {
    calls.push([name, args]);
    return { data: name.includes('prepare') ? posted ? { status: 'posted', amountCents: 300 } : { status: 'pending', charges }
      : { status: args.p_cancel ? 'cancelled' : 'posted', amountCents: 300 }, error: null };
  } } });
  vm.runInContext(edgeCode, context);
  return { calls, stripe, run: action => context.recordExternalTollPayment({}, { rentalId: 'rental', idempotencyKey: 'key', tollPayment: { amountCents: 300 }, action }) };
}
test('reserves first, retires every checkout and intent, then posts once', async () => {
  const f = fixture(); await f.run('admin_record_external_tolls');
  assert.equal(f.calls[0][0], 'service_prepare_external_toll_receipt');
  assert.deepEqual(f.calls.filter(c => c[0] === 'cancelIntent').map(c => c[1]), ['pi_one', 'pi_two']);
  assert.equal(f.calls.at(-1)[0], 'service_finish_external_toll_receipt');
});
for (const [name, options] of [
  ['completed checkout', { checkout: 'complete' }], ['captured payment', { intent: 'succeeded' }],
  ['processing payment', { intent: 'processing' }], ['capture pending', { intent: 'requires_capture' }],
  ['provider timeout', { providerFailure: true }], ['permission denied', { denied: true }],
]) test(`${name} cannot finalize or partially record a receipt`, async () => {
  const f = fixture(options); await assert.rejects(f.run('admin_record_external_tolls'));
  assert.equal(f.calls.some(c => c[0] === 'service_finish_external_toll_receipt'), false);
});
test('posted retry returns the original result without touching Stripe', async () => {
  const f = fixture({ posted: true }); const result = await f.run('admin_record_external_tolls');
  assert.equal(result.status, 'posted'); assert.equal(f.calls.length, 1);
});
test('cancellation uses the atomic release and performs no provider calls', async () => {
  const f = fixture(); const result = await f.run('admin_cancel_external_tolls');
  assert.equal(result.status, 'cancelled'); assert.equal(f.calls.length, 1); assert.equal(f.calls[0][1].p_cancel, true);
});
test('resume tolerates already-expired sessions and cancelled intents', async () => {
  const f = fixture({ checkout: 'expired', intent: 'canceled' }); await f.run('admin_record_external_tolls');
  assert.equal(f.calls.some(c => ['expire', 'cancelIntent'].includes(c[0])), false);
  assert.equal(f.calls.at(-1)[0], 'service_finish_external_toll_receipt');
});
test('unresolved saved-card creation is rejected', async () => {
  await assert.rejects(closeTollCollectionPaths({}, [{ admin_charge_attempted_at: '2026-11-05' }]), /unresolved/);
});
