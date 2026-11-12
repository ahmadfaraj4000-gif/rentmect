import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';

// Run the real Edge handler against fake providers; no Stripe/network calls.
const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const handler = stripTypeScriptTypes(source.slice(source.indexOf('async function retireRentalPaymentAttempts('), source.indexOf('async function recordAdminExternalBalance(')));
function fixture({ stale = false, duplicate = false, extension = false, revision = false, discount = false, processing = false, starting = false } = {}) {
  const calls = [];
  const charge = { id: 'balance', charge_type: 'rental_amendment', status: 'checkout_open', stripe_checkout_session_id: 'cs_open', stripe_payment_intent_id: null };
  if (processing) charge.stripe_payment_intent_id = 'pi_processing';
  if (starting) charge.stripe_checkout_session_id = null;
  const late = { id: 'late', status: 'pending', total_amount: 35, description: 'Existing late fee', stripe_checkout_session_id: 'cs_late' };
  class Query {
    constructor(table) { this.table = table; this.filters = []; this.write = null; }
    select() { return this; } eq(k,v) { this.filters.push([k,v]); return this; }
    in() { return this; } is() { return this; } order() { return this; }
    single() { return this; } maybeSingle() { return this; }
    update(value) { this.write = value; return this; }
    then(resolve, reject) {
      if (this.write) calls.push({ write: this.table, values: this.write, filters: this.filters });
      const data = ['rental_vehicle_swaps', 'rental_admin_extension_revisions', 'rental_admin_extensions', 'rental_amendments'].includes(this.table) ? (duplicate ? {id:'key'} : null)
        : this.table === 'rentals' ? {id:'rental',paid_at:'2026-09-17'}
        : this.write ? charge : this.filters.some(([k,v]) => k === 'source_type' && v === 'late_return') ? [late] : [charge];
      return Promise.resolve({ data, error: null }).then(resolve,reject);
    }
  }
  const client = { from: (table) => new Query(table), rpc: async (name,args) => {
    calls.push({rpc:name,args});
    return {data:['admin_preview_vehicle_swap', 'admin_preview_rental_extension_revision', 'admin_preview_rental_extension'].includes(name) ? {revision: stale ? 'changed' : 'reviewed'}
      : name === 'sync_rental_remaining_balance' ? {balance_due:156.33,net_paid:654.15,balance_charge_id:'balance'}
      : {idempotent_replay:duplicate},error:null};
  }};
  const context = vm.createContext({
    HttpError: Error, requireAdmin: async()=>({user:{id:'admin'}}), authenticatedClient:()=>client, adminClient:client,
    stripe:{paymentIntents:{retrieve:async(id)=>({id,status:'processing'})},checkout:{sessions:{retrieve:async(id)=>({id,status:'open',payment_status:'unpaid'}),expire:async(id)=>{calls.push({expire:id});}}}},
  });
  vm.runInContext(handler,context);
  return {calls,run:()=>context[discount ? 'applyAdminManualDiscount' : 'applyAdminRentalAmendment']({}, {action:revision ? 'admin_apply_rental_extension_revision' : extension ? 'admin_apply_rental_extension' : 'admin_apply_vehicle_swap',rentalId:'rental',vehicleId:'audi',
    discountMode:'fixed',discountValue:40,
    returnDate:'2026-10-08',returnTime:'9:00 AM',
    outgoingMileage:1100,incomingMileage:1000,effectiveAt:'2026-09-23T13:00:00Z',swapKind:'emergency',dailyRate:null,reason:'Emergency replacement agreed',idempotencyKey:'key',expectedRevision:'reviewed',waiveLateFees:true})};
}
test('swap retires old checkout, submits only swap fields, and preserves late fees',async()=>{
  const f=fixture();await f.run();
  assert.ok(f.calls.some(c=>c.expire==='cs_open'));
  assert.equal(f.calls.some(c=>c.expire==='cs_late'),false);
  const commit=f.calls.find(c=>c.rpc==='admin_apply_vehicle_swap');
  assert.equal(commit.args.p_effective_at,'2026-09-23T13:00:00Z');
  assert.equal(commit.args.p_daily_rate,null);
  assert.equal('p_pickup_date' in commit.args,false);
  assert.equal('p_return_date' in commit.args,false);
  assert.equal(f.calls.some(c=>c.write && c.filters.some(([k,v])=>k==='id'&&v==='late')),false);
  assert.ok(f.calls.findIndex(c=>c.expire==='cs_open')<f.calls.indexOf(commit));
});
test('admin extension retires old checkout before appending dates and leaves existing late fees alone',async()=>{
  const f=fixture({extension:true});await f.run();
  const commit=f.calls.find(c=>c.rpc==='admin_apply_rental_extension');
  assert.equal(commit.args.p_return_date,'2026-10-08');
  assert.equal(commit.args.p_return_time,'9:00 AM');
  assert.equal('p_pickup_date' in commit.args,false);
  assert.equal('p_vehicle_id' in commit.args,false);
  assert.ok(f.calls.findIndex(c=>c.expire==='cs_open')<f.calls.indexOf(commit));
  assert.equal(f.calls.some(c=>c.expire==='cs_late'),false);
  assert.equal(f.calls.some(c=>c.rpc==='admin_apply_rental_amendment'),false);
});
test('admin extension rejects a stale review before changing payment links',async()=>{
  const f=fixture({extension:true,stale:true});await assert.rejects(f.run(),/Review the extension again/);
  assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc==='admin_apply_rental_extension'),false);
});
test('admin extension retry does not expire or reset newly created payment links',async()=>{
  const f=fixture({extension:true,duplicate:true});const result=await f.run();
  assert.equal(result.idempotent_replay,true);
  assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc==='admin_preview_rental_extension'),false);
});
test('stale review rejects before expiring payment links or changing records',async()=>{
  const f=fixture({stale:true});await assert.rejects(f.run(),/Review the swap again/);
  assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc==='admin_apply_vehicle_swap'),false);
});
test('retry returns the committed swap without resetting or expiring payment links',async()=>{
  const f=fixture({duplicate:true});const result=await f.run();
  assert.equal(result.idempotent_replay,true);
  assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc==='admin_preview_vehicle_swap'),false);
});
test('discount retires the existing balance link before changing invoice cents',async()=>{
  const f=fixture({discount:true});await f.run();
  const commit=f.calls.findIndex(c=>c.rpc==='admin_apply_manual_rental_discount');
  assert.ok(commit>=0);
  assert.ok(f.calls.findIndex(c=>c.expire==='cs_open')<commit);
  assert.equal(f.calls.some(c=>c.expire==='cs_late'),false);
});
test('discount retry preserves newer payment attempts',async()=>{
  const f=fixture({discount:true,duplicate:true});await f.run();
  assert.equal(f.calls.some(c=>c.write||c.expire),false);
});

test('extension checkout requires the revised signature before contacting Stripe',async()=>{
  const checkoutHandler = source.slice(source.indexOf('async function createExtensionCheckout('), source.indexOf('async function createAdminExtensionCheckout('))
    .replace('req: Request, payload: CheckoutPayload, userId: string', 'req, payload, userId')
    .replaceAll('stripe!', 'stripe');
  for (const signed of [false, true]) {
    const calls = [];
    const request = {id:'extension',rental_id:'rental',user_id:'customer',status:'approved_pending_payment',payment_status:'pending',
      extension_total_amount:513.67,rentals:{agreement_signed:signed,vehicles:{name:'Audi'}}};
    const query = {select(){return this;},eq(){return this;},single:async()=>({data:request}),update(){calls.push('saved');return this;}};
    const context = vm.createContext({assertPaymentCreationEnabled(){},adminClient:{from:()=>query,rpc:async()=>({data:true})},
      requireMatchingStoredIdentity:async()=>{calls.push('identity');},reusableCheckout:async()=>({idempotencyKey:'extension'}),
      cents:(v)=>Math.round(v*100),checkoutUrls:()=>({successUrl:'https://example.test/success',cancelUrl:'https://example.test/cancel'}),
      stripe:{checkout:{sessions:{create:async(params)=>{calls.push(params.line_items[0].price_data.unit_amount);return {id:'cs_test',url:'https://example.test/checkout'};}}}}});
    vm.runInContext(checkoutHandler,context);
    if (!signed) {
      await assert.rejects(context.createExtensionCheckout({}, {extensionRequestId:'extension'}, 'customer'),/Sign the updated rental agreement/);
      assert.deepEqual(calls,[]);
    } else {
      const result=await context.createExtensionCheckout({}, {extensionRequestId:'extension'}, 'customer');
      assert.equal(result.sessionId,'cs_test');
      assert.ok(calls.includes(51367));
    }
  }
});
test('discount, swap and extension refuse an in-flight captured/processing payment',async()=>{
  for (const kind of [{discount:true},{extension:true},{}]) {
    const f=fixture({...kind,processing:true});
    await assert.rejects(f.run(),/already processing or captured/);
    assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc?.startsWith('admin_apply_')),false);
  }
});
test('discount, swap and extension refuse an attempt still acquiring its Stripe identifiers',async()=>{
  for (const kind of [{discount:true},{extension:true},{}]) {
    const f=fixture({...kind,starting:true});
    await assert.rejects(f.run(),/payment attempt is starting/);
    assert.equal(f.calls.some(c=>c.write||c.expire||c.rpc?.startsWith('admin_apply_')),false);
  }
});

test('extension revision expires old collection links before saving, while retries preserve newer links', async () => {
  const f = fixture({ revision: true }); await f.run();
  const commit = f.calls.find(c => c.rpc === 'admin_apply_rental_extension_revision');
  assert.equal(commit.args.p_return_date, '2026-10-08');
  assert.ok(f.calls.findIndex(c => c.expire === 'cs_open') < f.calls.indexOf(commit));
  const retry = fixture({ revision: true, duplicate: true }); await retry.run();
  assert.equal(retry.calls.some(c => c.write || c.expire), false);
});
