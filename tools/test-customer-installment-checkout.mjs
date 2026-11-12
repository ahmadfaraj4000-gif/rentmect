import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { chargeCollectionCents } from '../supabase/functions/_shared/charge-collection-amount.js';

const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const handlers = stripTypeScriptTypes([
  source.slice(source.indexOf('async function reusableCheckout('), source.indexOf('function identityReturnUrl(')),
  source.slice(source.indexOf('async function createRentalCheckout('), source.indexOf('async function createAdminRentalChargeCheckout(')),
].join('\n'));

function fixture(options = {}) {
  const calls = [];
  const rental = { id: 'rental', user_id: 'customer', status: 'active', payment_status: 'partially_paid', agreement_signed: true, ...options.rental };
  const installment = { id: 'installment', rental_id: rental.id, user_id: 'customer', charge_type: 'rental_installment', status: 'checkout_open', total_amount: 513.67, stripe_checkout_session_id: 'cs_existing', created_at: new Date().toISOString(), ...options.installment };
  const balance = { id: 'balance', rental_id: rental.id, user_id: 'customer', charge_type: 'rental_amendment', status: 'pending', total_amount: 513.67, ...options.balance };
  const charges = [balance, ...(options.noInstallment ? [] : [installment])];
  let retrieved = 0;
  const session = { id: 'cs_existing', status: 'open', payment_status: 'unpaid', mode: 'payment', currency: 'usd', amount_total: 51367, url: 'https://checkout.stripe.com/existing', metadata: { target_type: 'charge', charge_id: installment.id, rental_id: rental.id, user_id: 'customer' }, ...options.session };
  class Query {
    constructor(table) { this.table = table; this.filters = []; }
    select() { return this; }
    eq(k,v) { this.filters.push(row => row[k] === v); return this; }
    is(k,v) { this.filters.push(row => v === null ? row[k] == null : row[k] === v); return this; }
    in(k,v) { this.filters.push(row => v.includes(row[k])); return this; }
    order() { return this; } limit() { return this; }
    single() { this.one = true; return this; } maybeSingle() { this.one = true; return this; }
    update(values) { this.values = values; return this; }
    then(resolve,reject) {
      const rows = (this.table === 'rentals' ? [rental] : charges).filter(row => this.filters.every(f => f(row)));
      if (this.values) { calls.push(['update', this.table]); rows.forEach(row => Object.assign(row, this.values)); }
      return Promise.resolve({ data: this.one ? rows[0] : rows, error: null }).then(resolve,reject);
    }
  }
  const context = vm.createContext({ chargeCollectionCents, crypto,
    Date, HttpError: Error, assertPaymentCreationEnabled() {}, cents: v => Math.round(Number(v)*100),
    checkoutUrls: () => ({successUrl:'https://example.test/success',cancelUrl:'https://example.test/cancel'}),
    adminClient: { from: table => new Query(table), rpc: async (name,args) => {
      calls.push(['rpc',name]);
      if (name === 'retire_expired_stripe_rental_installment') { installment.status = 'waived'; return {data: true}; }
      if (name === 'sync_rental_remaining_balance') return {data:{balance_due: options.due ?? 513.67}, error: options.settlementError};
      throw new Error(`Unexpected RPC ${name}`);
    }},
    stripe: { paymentIntents: {retrieve: async () => ({status: options.intentStatus})}, checkout: { sessions: {
      retrieve: async () => { calls.push(['retrieve']); retrieved++; if (options.providerError) throw new Error('Stripe unavailable'); return retrieved > 1 && options.sessionAfter ? {...session,...options.sessionAfter} : session; },
      expire: async () => { calls.push(['expire']); },
      create: async params => {calls.push(['create',params.line_items[0].price_data.unit_amount]); return {id:'cs_new',url:'https://checkout.stripe.com/new'};},
    }}},
  });
  vm.runInContext(handlers, context);
  return { calls, run: (route = 'rental', user = 'customer') => route === 'rental'
    ? context.createRentalCheckout({}, {rentalId:'rental'}, user)
    : context.createRentalChargeCheckout({}, {chargeId:'balance'}, user) };
}
for (const route of ['rental','charge']) {
  test(`${route}: customer resumes the existing $513.67 session without a second checkout`, async () => {
    const f = fixture(); const result = await f.run(route);
    assert.equal(result.sessionId,'cs_existing'); assert.equal(result.targetId,'installment');
    assert.equal(result.reused,true); assert.equal(result.balanceAfterPayment,0);
    assert.equal(f.calls.some(([name]) => ['create','expire','update'].includes(name)),false);
  });
  test(`${route}: wrong customer cannot access the payment link`, async () => {
    const f = fixture(); await assert.rejects(f.run(route,'other'),/does not belong/); assert.deepEqual(f.calls,[]);
  });
  test(`${route}: unsigned agreement cannot resume an installment`, async () => {
    const f = fixture({rental:{agreement_signed:false}}); await assert.rejects(f.run(route),/Sign the revised/);
    assert.equal(f.calls.some(([name]) => name === 'create'),false);
  });
  test(`${route}: expired installment retires and normal balance checkout continues`, async () => {
    const f = fixture({session:{status:'expired',url:null}}); const result=await f.run(route);
    assert.equal(result.sessionId,'cs_new'); assert.ok(f.calls.some(([name,rpc])=>name==='rpc' && rpc==='retire_expired_stripe_rental_installment'));
    assert.deepEqual(f.calls.filter(([name])=>name==='create'),[['create',51367]]);
  });
}
test('a smaller authorized installment preserves its amount and remaining balance',async()=>{
  const f=fixture({installment:{total_amount:200},session:{amount_total:20000}}); const result=await f.run();
  assert.equal(result.installment,true); assert.equal(result.installmentAmount,200); assert.equal(result.balanceAfterPayment,313.67);
});
for (const [label,options,pattern] of [
  ['amount exceeds current due',{due:400},/no longer matches/],
  ['settled invoice',{due:0},/no longer matches/],
  ['wrong Stripe amount',{session:{amount_total:48300}},/could not be verified/],
  ['wrong currency',{session:{currency:'eur'}},/could not be verified/],
  ['wrong session owner',{session:{metadata:{target_type:'charge',charge_id:'installment',rental_id:'rental',user_id:'other'}}},/could not be verified/],
  ['wrong charge',{session:{metadata:{target_type:'charge',charge_id:'other',rental_id:'rental',user_id:'customer'}}},/could not be verified/],
  ['captured payment',{session:{status:'complete',payment_status:'paid'}},/completed an administrator/],
  ['processing intent',{installment:{stripe_payment_intent_id:'pi_processing'},intentStatus:'processing'},/processing or captured/],
  ['starting checkout',{installment:{stripe_checkout_session_id:null}},/still being prepared/],
  ['payment completes during handoff',{sessionAfter:{status:'complete',payment_status:'paid'}},/received and is being confirmed/],
  ['session expires during handoff',{sessionAfter:{status:'expired'}},/link has closed/],
  ['Stripe unavailable',{providerError:true},/Stripe unavailable/],
  ['settlement unavailable',{settlementError:{message:'Balance unavailable'}},/Balance unavailable/],
  ['cancelled rental',{rental:{status:'cancelled'}},/Cancelled rentals/],
]) test(`${label} never returns or creates another checkout`,async()=>{
  const f=fixture(options); await assert.rejects(f.run('charge'),pattern);
  assert.equal(f.calls.some(([name])=>['create','expire','update'].includes(name)),false);
});
test('unrelated fees are not silently redirected to an invoice installment',async()=>{
  const f=fixture({balance:{charge_type:'fuel'}}); await assert.rejects(f.run('charge'),/administrator-started/);
});
test('normal balance checkout still works without an installment',async()=>{
  const f=fixture({noInstallment:true}); const result=await f.run(); assert.equal(result.sessionId,'cs_new');
  assert.deepEqual(f.calls.filter(([name])=>name==='create'),[['create',51367]]);
});
