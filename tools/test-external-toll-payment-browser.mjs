// Actual modal and draft hook, synthetic local data. No live payment calls.
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = resolve(process.env.ADMIN_TEST_ROOT || 'rentmect-admin-portal');
const folder = await mkdtemp(root + '/.toll-test-');
const source = await readFile(root + '/src/main.jsx', 'utf8');
const modal = source.slice(source.indexOf('function TollExternalPaymentModal('), source.indexOf('function ChargeExternalPaymentModal('));
const focus = source.slice(source.indexOf('function useDialogFocus('), source.indexOf('class PortalErrorBoundary'));
await writeFile(folder + '/index.html', '<meta name="viewport" content="width=device-width, initial-scale=1"><div id="root"></div><script type="module" src="./test.jsx"></script>');
await writeFile(folder + '/test.jsx', `import React, {useState,useEffect,useRef} from 'react';
import {createRoot} from 'react-dom/client'; import {createPortal} from 'react-dom'; import {Banknote,X} from 'lucide-react';
import {eligibleExternalTolls,buildTollPayment,tollCents} from '../src/lib/externalTollPayment.js';
import {useTaskDraft,DraftOwnerContext} from '../src/useTaskDraft.js'; import {trackTaskDialog} from '../src/lib/taskDraft.js';
import '../src/styles.css'; import '../src/final-overrides.css';
const money=n=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(n);
const supabase={from(){return {filters:[],select(){return this},eq(k,v){this.filters.push([k,v]);return this},async maybeSingle(){const row=JSON.parse(sessionStorage.getItem('testReceipt')||'null');return {data:row&&this.filters.every(([k,v])=>k==='rental_id'||row[k]===v)?row:null,error:null}}}}};
${focus}\n${modal}
const charges=[{id:'one',name:'Bridge toll',description:'November 3 · Bridge crossing',charge_type:'toll',status:'pending',total_amount:2.31},{id:'two',name:'Highway toll',description:'November 4 · Highway exit',charge_type:'toll',status:'pending',total_amount:1.09},{id:'paid',name:'Paid toll',charge_type:'toll',status:'paid',total_amount:10}];
window.calls=[];
function App(){const [closed,setClosed]=useState(false);return closed?<p>Closed</p>:<TollExternalPaymentModal rental={{id:'rental',vehicles:{name:'Test Audi'}}} charges={charges} onClose={()=>setClosed(true)} onRecord={async(rentalId,id,request,cancel)=>{
window.calls.push({id,request,cancel});
if(cancel){sessionStorage.removeItem('testReceipt');return {status:'cancelled'}}
if(location.search.includes('fail')&&!sessionStorage.getItem('testFailed')){sessionStorage.setItem('testFailed','1');sessionStorage.setItem('testReceipt',JSON.stringify({id,status:'pending',request}));throw Error('Network interrupted. Resume this recording.');}
const result={status:'posted',receiptId:id,count:request.charges.length,amountCents:request.amountCents};sessionStorage.setItem('testReceipt',JSON.stringify({id,status:'posted',request,result}));if(location.search.includes('fail')&&!sessionStorage.getItem('testLostResponse')){sessionStorage.setItem('testLostResponse','1');throw Error('Posted response lost. Resume to check.');}return result;
}}/>};createRoot(document.getElementById('root')).render(<DraftOwnerContext.Provider value="test-staff"><App/></DraftOwnerContext.Provider>);`);
const server = spawn(process.execPath, [root + '/node_modules/vite/bin/vite.js', '--host','127.0.0.1','--port','5197','--strictPort'],{cwd:root,stdio:['ignore','pipe','pipe']});
let browser;
try {
 await new Promise((ready,reject)=>{server.stdout.on('data',d=>{if(d.toString().includes('Local:'))ready()});server.on('error',reject);server.on('exit',()=>reject(Error('Vite exited')))});
 browser=await chromium.launch({headless:true,channel:process.env.PLAYWRIGHT_CHANNEL||'chrome'});
 const url='http://127.0.0.1:5197/'+folder.split('/').at(-1)+'/index.html';
 for(const mobile of [false,true]){
 const context=await browser.newContext({viewport:mobile?{width:390,height:720}:{width:1280,height:900}});const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(url+'?fail=1');
 await page.getByLabel('Select all unpaid tolls (2)').check();
 await page.getByLabel('Amount received').fill('3.39');
 await page.getByLabel(/I confirm this payment/).check();
 await page.getByRole('button',{name:'Apply payment to selected tolls'}).click();
 await page.getByRole('alert').filter({hasText:'exactly match'}).waitFor();
 assert.equal(await page.evaluate(()=>window.calls.length),0);
 await page.getByLabel('Amount received').fill('3.40');await page.getByLabel(/I confirm this payment/).check();
 await page.screenshot({path:'/tmp/rentme-toll-batch-20261105/toll-'+(mobile?'mobile':'desktop')+'.png',fullPage:true});
 await page.getByRole('button',{name:'Apply payment to selected tolls'}).click();
 await page.getByRole('alert').filter({hasText:'Network interrupted'}).waitFor();
 const receiptId=await page.evaluate(()=>window.calls[0].id);
 await page.reload();await page.getByRole('button',{name:'Resume recording'}).waitFor();
 assert.equal(await page.getByLabel('Amount received').isDisabled(),true);
 assert.equal(await page.getByLabel(/I confirm this payment/).isChecked(),false);
 await page.getByLabel(/I confirm this payment/).check();await page.getByRole('button',{name:'Resume recording'}).click();
 await page.getByRole('alert').filter({hasText:'Posted response lost'}).waitFor();
 assert.equal(await page.evaluate(()=>window.calls[0].id),receiptId);
 await page.reload();await page.getByRole('status').filter({hasText:'$3.40 recorded across 2 tolls'}).waitFor();
 assert.equal(await page.evaluate(()=>window.calls.length),0);
 assert.deepEqual(errors,[]);await context.close();
 }
 console.log('PASS: desktop/mobile selection, exact amount validation, timeout/reload recovery, unchanged receipt key, no duplicate payment, posted receipt recovery.');
} finally {await browser?.close();server.kill('SIGTERM');await rm(folder,{recursive:true,force:true});}
