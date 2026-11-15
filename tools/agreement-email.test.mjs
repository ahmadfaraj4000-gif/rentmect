import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import vm from 'node:vm';
import {agreementCopy} from '../supabase/functions/_shared/agreementCopy.js';
const source=readFileSync(new URL('../supabase/functions/send-emails/index.ts',import.meta.url),'utf8');
const code=stripTypeScriptTypes(source.slice(source.indexOf('async function handleAgreementEmail('),source.indexOf('async function handleWebhook(')));
function setup({signed=true,email='saved@example.com',authorized=true}={}){
 const sent=[],records=[];const rental={id:'r',user_id:'u',agreement_signed:signed,agreement_snapshot:'Signed terms',agreement_signature_name:'Jane Smith',pickup_date:'2026-11-24',return_date:'2026-11-26'};
 const client={from(table){return {select(){return this},eq(){return this},async single(){return {data:table==='rentals'?rental:{email,full_name:'Jane Smith'}}},async insert(row){records.push(row);return {}}}}};
 const ctx={TextEncoder,btoa,agreementCopy,Date,String,requireAdmin:async(_r,p)=>{assert.equal(p,'communications.send');if(!authorized)throw Error('Unauthorized');return{id:'admin'}},adminClient:client,json:(data,status=200)=>({data,status}),dateLabel:v=>v,escapeHtml:v=>v,emailShell:v=>v,sendMail:async p=>{sent.push(p);return'message'}};
 return {run:vm.runInNewContext(code+';handleAgreementEmail',ctx),sent,records};
}
test('signed agreement emails the address on file with named attachment',async()=>{
 const h=setup();const result=await h.run({json:async()=>({rentalId:'r',recipient:'attacker@example.com'})});
 assert.equal(result.status,200);assert.equal(h.sent[0].to,'saved@example.com');
 assert.equal(h.sent[0].attachments[0].filename,'Jane Smith - Agreement - 2026-11-24 to 2026-11-26.html');
 assert.match(atob(h.sent[0].attachments[0].content),/Signed terms/);assert.equal(h.records[0].rental_id,'r');
});
test('unsigned, missing email and unauthorized requests never send',async()=>{
 for(const options of [{signed:false},{email:''}]){const h=setup(options);assert.ok((await h.run({json:async()=>({rentalId:'r'})})).status>=400);assert.equal(h.sent.length,0)}
 const h=setup({authorized:false});await assert.rejects(h.run({json:async()=>({rentalId:'r'})}),/Unauthorized/);assert.equal(h.sent.length,0);
});
