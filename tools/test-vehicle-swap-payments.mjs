import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Run the real Edge handler against fake providers; no Stripe/network calls.
const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const handler = source.slice(source.indexOf('async function applyAdminRentalAmendment('), source.indexOf('async function applyAdminManualDiscount('))
  .replace('req: Request, payload: CheckoutPayload', 'req, payload')
  .replaceAll(': string | null | undefined', '')
  .replaceAll('adminClient!', 'adminClient').replaceAll('stripe!', 'stripe').replaceAll('lateFeeCharges!', 'lateFeeCharges');
function fixture({ stale = false, duplicate = false, extension = false } = {}) {
  const calls = [];
  const charge = { id: 'balance', charge_type: 'rental_amendment', status: 'checkout_open', stripe_checkout_session_id: 'cs_open', stripe_payment_intent_id: null };
  const late = { id: 'late', status: 'pending', total_amount: 35, description: 'Existing late fee', stripe_checkout_session_id: 'cs_late' };
  class Query {
    constructor(table) { this.table = table; this.filters = []; this.write = null; }
    select() { return this; } eq(k,v) { this.filters.push([k,v]); return this; }
    in() { return this; } is() { return this; } order() { return this; }
    single() { return this; } maybeSingle() { return this; }
    update(value) { this.write = value; return this; }
    then(resolve, reject) {
      if (this.write) calls.push({ write: this.table, values: this.write, filters: this.filters });
      const data = ['rental_vehicle_swaps', 'rental_admin_extensions'].includes(this.table) ? (duplicate ? {id:'key'} : null)
        : this.table === 'rentals' ? {id:'rental',paid_at:'2026-09-17'}
        : this.write ? charge : this.filters.some(([k,v]) => k === 'source_type' && v === 'late_return') ? [late] : [charge];
      return Promise.resolve({ data, error: null }).then(resolve,reject);
    }
  }
  const client = { from: (table) => new Query(table), rpc: async (name,args) => {
    calls.push({rpc:name,args});
    return {data:['admin_preview_vehicle_swap', 'admin_preview_rental_extension'].includes(name) ? {revision: stale ? 'changed' : 'reviewed'}
      : name === 'sync_rental_remaining_balance' ? {balance_due:156.33,net_paid:654.15,balance_charge_id:'balance'}
      : {idempotent_replay:duplicate},error:null};
  }};
  const context = vm.createContext({
    HttpError: Error, requireAdmin: async()=>({user:{id:'admin'}}), authenticatedClient:()=>client, adminClient:client,
    stripe:{checkout:{sessions:{retrieve:async(id)=>({id,status:'open',payment_status:'unpaid'}),expire:async(id)=>{calls.push({expire:id});}}}},
  });
  vm.runInContext(handler,context);
  return {calls,run:()=>context.applyAdminRentalAmendment({}, {action:extension ? 'admin_apply_rental_extension' : 'admin_apply_vehicle_swap',rentalId:'rental',vehicleId:'audi',
    returnDate:'2026-10-08',returnTime:'9:00 AM',
    effectiveAt:'2026-09-23T13:00:00Z',swapKind:'emergency',dailyRate:null,reason:'Emergency replacement agreed',idempotencyKey:'key',expectedRevision:'reviewed',waiveLateFees:true})};
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
