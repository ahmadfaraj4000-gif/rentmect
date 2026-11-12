import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import vm from 'node:vm';
import {chargeCollectionCents} from '../supabase/functions/_shared/charge-collection-amount.js';
import {closeTollCollectionPaths} from '../supabase/functions/_shared/external-toll-payment.js';
const source=readFileSync(new URL('../supabase/functions/stripe-web-hook/index.ts',import.meta.url),'utf8');
const extract=(a,b)=>stripTypeScriptTypes(source.slice(source.indexOf(a),source.indexOf(b,source.indexOf(a)+a.length)));
const code=extract('async function createRentalChargeCheckout','async function createAdminRentalChargeCheckout')+'\n'+extract('async function chargeSavedCard','async function ');
function fixture(options={}){
 const calls=[];
 const charge={id:'fee',rental_id:'rental',user_id:'customer',name:'Toll',charge_type:'toll',status:'pending',total_amount:26,allocation_managed:true,allocated_payment_cents:1000,allocated_deposit_cents:0,allocated_waiver_cents:0,admin_charge_attempts:0,...options.charge};
 const rental={id:'rental',user_id:'customer',stripe_customer_id:'cus_test',stripe_payment_intent_id:'pi_original'};
 class Query{
  constructor(table){this.table=table;this.filters=[];}
  select(){return this;} eq(k,v){this.filters.push(x=>x[k]===v);return this;} neq(k,v){this.filters.push(x=>x[k]!==v);return this;}
  is(k,v){this.filters.push(x=>v==null?x[k]==null:x[k]===v);return this;} in(k,v){this.filters.push(x=>v.includes(x[k]));return this;}
  single(){this.one=true;return this;} maybeSingle(){this.one=true;return this;} order(){return this;} limit(){return this;} not(){return this;}
  update(v){this.patch=v;return this;} insert(v){calls.push(['audit',v]);return this;}
  then(resolve,reject){
   let rows=this.table==='rental_charge_items'?[charge]:this.table==='rentals'?[rental]:this.table==='profiles'?[{id:'customer',email:'synthetic@example.test'}]:this.table==='external_payment_receipts'&&options.posted?[{id:'receipt',stripe_payment_intent_id:'pi_prior',stripe_checkout_session_id:'cs_prior',status:'posted'}]:[];
   if(this.patch&&options.race&&!this.raced){charge.allocated_payment_cents=1500;this.raced=true;}
   rows=rows.filter(x=>this.filters.every(f=>f(x)));
   if(this.patch){calls.push(['update',this.patch]);rows.forEach(x=>Object.assign(x,this.patch));}
   // Supabase reads return snapshots, not mutable references.
   const data=JSON.parse(JSON.stringify(this.one?rows[0]||null:rows));
   return Promise.resolve({data,error:null}).then(resolve,reject);
  }
 }
 let intent;
 const stripe={checkout:{sessions:{retrieve:async()=>({id:'cs_prior',status:'open',payment_status:'unpaid'}),expire:async id=>calls.push(['expire',id]),create:async p=>{calls.push(['checkout',p.line_items[0].price_data.unit_amount]);return{id:'cs_new',url:'https://checkout.stripe.com/test'};}}},paymentIntents:{
  retrieve:async id=>({id,status:id==='pi_prior'?'succeeded':'canceled',payment_method:'pm_test'}),
  cancel:async id=>calls.push(['cancel',id]),
  create:async p=>{calls.push(['intent',p.amount]);intent={id:'pi_new',amount_received:p.amount,currency:'usd',status:'requires_confirmation'};return intent;},
  confirm:async()=>{calls.push(['confirm']);return {...intent,status:options.status||'succeeded'};},
 }};
 const context=vm.createContext({chargeCollectionCents,closeTollCollectionPaths,crypto,Date,Error,
 assertPaymentCreationEnabled(){},requireAdmin:async()=>({user:{id:'admin'}}),findActiveAdminInstallment:async()=>null,
 reusableCheckout:async id=>{calls.push(['reuse',id]);return{};},checkoutUrls:()=>({successUrl:'https://example.test',cancelUrl:'https://example.test'}),
 stripe,adminClient:{from:t=>new Query(t)},recordAdminSavedCardCharge:async(c,p)=>{calls.push(['post',p.amount_received]);return{...charge,status:'paid'};},openReconciliationIssue:async()=>{},
 });vm.runInContext(code,context);
 return {calls,charge,checkout:()=>context.createRentalChargeCheckout({}, {chargeId:'fee'},'customer'),saved:()=>context.chargeSavedCard({}, {chargeId:'fee'})};
}
test('checkout and saved card collect $16 after $10 external allocation on a $26 toll',async()=>{
 const c=fixture();await c.checkout();assert.deepEqual(c.calls.filter(x=>x[0]==='checkout'),[['checkout',1600]]);
 const s=fixture();assert.equal((await s.saved()).status,'succeeded');assert.deepEqual(s.calls.filter(x=>x[0]==='intent'||x[0]==='post'),[['intent',1600],['post',1600]]);assert.equal(s.charge.total_amount,26);
});
test('mixed deposit checkout preserves the deposit funding marker and collects only $10',async()=>{
 const f=fixture({charge:{allocated_payment_cents:0,allocated_deposit_cents:1600,payment_provider:'deposit'}});await f.checkout();assert.equal(f.charge.payment_provider,'deposit');assert.equal(f.charge.payment_amount_cents,1000);
});
test('changed allocation before reservation prevents both provider paths',async()=>{
 const c=fixture({race:true});await assert.rejects(c.checkout(),/Another collection/);assert.equal(c.calls.some(x=>x[0]==='checkout'),false);
 const s=fixture({race:true});assert.equal((await s.saved()).status,'processing');assert.equal(s.calls.some(x=>x[0]==='intent'),false);
});
test('already posted Stripe funds do not block collection after an external portion is refunded',async()=>{
 for(const route of ['checkout','saved']){const f=fixture({posted:true,charge:{allocated_payment_cents:1600,stripe_payment_intent_id:'pi_prior',stripe_checkout_session_id:'cs_prior'}});await f[route]();assert.equal(f.calls.find(x=>x[0]===(route==='checkout'?'checkout':'intent'))[1],1000);assert.equal(f.calls.some(x=>x[0]==='cancel'),false);}
});
test('authentication-required saved card never posts a receipt',async()=>{const f=fixture({status:'requires_action'});assert.equal((await f.saved()).status,'customer_action_required');assert.equal(f.calls.some(x=>x[0]==='post'),false);});
test('in-progress saved card cannot start another provider collection',async()=>{for(const route of ['checkout','saved']){const f=fixture({charge:{admin_charge_attempted_at:'2026-11-11',stripe_payment_intent_id:null}});if(route==='checkout')await assert.rejects(f[route](),/starting/);else assert.equal((await f[route]()).status,'processing');assert.equal(f.calls.some(x=>['checkout','intent'].includes(x[0])),false);}});
test('invalid allocated counters cannot create a negative or overlarge collection',()=>{for(const c of [{total_amount:26,allocation_managed:true,allocated_payment_cents:2601},{total_amount:26,allocation_managed:true,allocated_payment_cents:-1}])assert.throws(()=>chargeCollectionCents(c));});

test('checkout after a failed saved-card attempt clears its starting marker and remains resumable',async()=>{const f=fixture({charge:{stripe_payment_intent_id:'pi_failed',admin_charge_attempted_at:'2026-11-11'}});await f.checkout();assert.equal(f.charge.admin_charge_attempted_at,null);await f.checkout();});
