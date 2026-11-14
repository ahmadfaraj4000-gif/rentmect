import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {webcrypto} from 'node:crypto';
import {adminError} from '../supabase/functions/_shared/admin-errors.js';
const source=readFileSync(new URL('../supabase/functions/admin-manual-booking/index.ts',import.meta.url),'utf8');
function fixture(rpcError=null) {
 let handler,calls=0;
 class Query { constructor(table){this.table=table;} select(){return this;}eq(){return this;}update(){return this;}single(){return this;}then(ok,no){return Promise.resolve({data:this.table==='profiles'?{role:'admin',staff_role:'owner',full_name:'Synthetic Customer'}:{id:'rental'},error:null}).then(ok,no);} }
 const client={auth:{getUser:async()=>({data:{user:{id:'staff'}}})},from:t=>new Query(t),rpc:async()=>{calls++;return {data:rpcError?null:{id:'rental'},error:rpcError};}};
 const context=vm.createContext({Request,Response,URL,console:{error(){},warn(){}},crypto:webcrypto,TextEncoder,adminError,createClient:()=>client,Deno:{env:{get:key=>key.startsWith('SUPABASE_')?'synthetic':undefined},serve:fn=>handler=fn}});
 vm.runInContext(stripTypeScriptTypes(source.replace(/^import .*;\n/gm,'')),context);
 return {run:async(extra={})=>handler(new Request('https://test.invalid',{method:'POST',headers:{authorization:'Bearer synthetic'},body:JSON.stringify({customerMode:'existing',customerId:'customer',vehicleId:'vehicle',pickupDate:'2026-12-01',returnDate:'2026-12-02',onboardingDelivery:'none',...extra})})),get calls(){return calls;}};
}
test('actual booking handler preserves the production plain-object overlap rejection',async()=>{
 const f=fixture({code:'P0001',message:'This customer already has a rental scheduled during those dates and times. A customer can use only one rental vehicle at a time.'});
 const response=await f.run(),body=await response.json();assert.equal(response.status,400);assert.equal(body.code,'CUSTOMER_DATES_OVERLAP');assert.match(body.error,/already has a reservation/);assert.equal(body.field,'customerId');assert.match(body.requestId,/^[a-f0-9-]{36}$/);assert.equal(f.calls,1);
});
test('successful booking keeps its explicit acknowledgement',async()=>{const f=fixture();const r=await f.run();assert.equal(r.status,200);assert.equal((await r.json()).rental.id,'rental');assert.equal(f.calls,1);});
test('invalid payment preference is rejected before a rental is created',async()=>{const f=fixture();assert.equal((await f.run({paymentCollectionPreference:'invalid'})).status,400);assert.equal(f.calls,0);});
test('unknown errors give a reference without exposing SQL internals',async()=>{const f=fixture({message:'SQL statement SELECT token FROM secrets'});const b=await (await f.run()).json();assert.equal(b.code,'UNEXPECTED_ERROR');assert.doesNotMatch(b.error,/SELECT|secrets/);assert.ok(b.requestId);});
