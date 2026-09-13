import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

// Execute the actual handler with in-memory provider responses. Never call Stripe.
const source = readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts', import.meta.url), 'utf8');
const handler = source.slice(source.indexOf('async function refundRentalPayment('), source.indexOf('\nasync function syncPendingDepositRefunds'))
  .replace('req: Request, payload: CheckoutPayload', 'req, payload')
  .replaceAll('adminClient!', 'adminClient').replaceAll('stripe!', 'stripe');
const request = { rentalId: 'rental', chargeId: 'balance', amountCents: 10000,
  refundRequestId: '00000000-0000-4000-8000-000000000001', reason: 'Customer adjustment' };
function fixture({ allocations = [], chargeRentalId = 'rental', existing = null, fail = false } = {}) {
  const calls = [], writes = [];
  const rental = { id: 'rental', user_id: 'customer', payment_status: 'paid', payment_provider: 'stripe', stripe_payment_intent_id: null, payment_amount_cents: 82835 };
  const balance = { id: 'balance', rental_id: chargeRentalId, charge_type: 'rental_amendment', status: 'paid', payment_provider: 'stripe', stripe_payment_intent_id: 'pi_balance', payment_amount_cents: 52835 };
  class Query {
    constructor(table) { this.table=table; this.filters=[]; this.mode='read'; }
    select(){return this;}
    eq(k,v){this.filters.push([k,v]);return this;}
    is(k,v){return this.eq(k,v);}
    insert(v){this.mode='insert'; this.values=v;return this;}
    update(v){this.mode='update';this.values=v;return this;}
    single(){return this;}
    maybeSingle(){return this;}
    then(resolve,reject){
      if(this.mode!=='read'){writes.push({table:this.table,values:this.values,filters:this.filters});return Promise.resolve({error:null}).then(resolve,reject);}
      let data = this.table==='rentals'?rental:this.table==='rental_charge_items'?balance:this.table==='rental_deposit_allocations'?allocations:existing;
      if(data&&!Array.isArray(data)&&!this.filters.every(([k,v])=>data[k]===v))data=null;
      return Promise.resolve({data,error:null}).then(resolve,reject);
    }
  }
  const context = vm.createContext({
    HttpError: Error, Stripe: {errors:{StripeInvalidRequestError:class extends Error {}}},
    requireAdmin: async()=>({user:{id:'admin'},profile:{email:'admin@example.test'}}),
    cents: n=>Math.round(n*100), moneyDescription:n=>`$${(n/100).toFixed(2)}`,
    normalizedRefundStatus:s=>s,
    adminClient:{from:table=>new Query(table),rpc:async(name,args)=>{
      calls.push({name,args}); return {data:name==='reserve_rental_payment_refund'?{id:request.refundRequestId,status:'processing'}:null,error:null};
    }},
    stripe:{paymentIntents:{retrieve:async id=>{calls.push({retrieve:id});return {amount_received:52835};}},
      charges:{list:async()=>({data:[{amount_refunded:0}]})},
      refunds:{create:async (params,options)=>{calls.push({refund:params,options});if(fail)throw new Error('Network response lost');return {id:'re_example',status:'succeeded'};}}},
  });
  vm.runInContext(handler,context);
  return {run:payload=>context.refundRentalPayment({},payload),calls,writes};
}
test('refunds the selected captured balance payment while leaving the $300 cash deposit alone',async()=>{
  const f=fixture();const result=await f.run(request);
  assert.equal(result.amount,10000);assert.equal(result.status,'succeeded');
  assert.deepEqual(JSON.parse(JSON.stringify(f.calls.find(c=>c.refund).refund)),{
    payment_intent:'pi_balance',amount:10000,metadata:{refund_type:'rental_payment',charge_id:'balance',refund_request_id:request.refundRequestId,rental_id:'rental',admin_user_id:'admin'}
  });
  assert.equal(f.writes.some(w=>w.table==='rentals'||w.table==='rental_deposit_allocations'),false);
});
test('rejects a balance payment belonging to a different rental',async()=>{
  const f=fixture({chargeRentalId:'other'});await assert.rejects(f.run(request),/not found/);
  assert.equal(f.calls.some(c=>c.refund),false);
});
test('protects deposits even when transferred to another rental',async()=>{
  const f=fixture({allocations:[{amount_held:500,amount_released:0,status:'transferred'}]});
  await assert.rejects(f.run(request),/maximum rental-payment refund/);assert.equal(f.calls.some(c=>c.refund),false);
});
test('an uncertain provider result remains reserved instead of being marked failed',async()=>{
  const f=fixture({fail:true});await assert.rejects(f.run(request),/Network response lost/);
  const write=f.writes.find(w=>w.table==='rental_payment_refunds');assert.equal(write.values.status,'processing');
  assert.ok(write.filters.some(([k,v])=>k==='stripe_refund_id'&&v===null));
});
test('repeating a confirmed refund does not send money again',async()=>{
  const f=fixture({existing:{id:request.refundRequestId,rental_id:'rental',amount:100,status:'succeeded',stripe_refund_id:'re_original'}});
  const result=await f.run(request);assert.equal(result.duplicate,true);assert.equal(f.calls.some(c=>c.refund),false);
});
