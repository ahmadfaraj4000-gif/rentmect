// Synthetic UI test of the real swap modal, time conversion, draft and availability hook.
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
const { chromium }=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root=resolve(process.env.ADMIN_TEST_ROOT || 'rentmect-admin-portal');
const folder=await mkdtemp(root+'/.swap-time-test-');
const source=await readFile(root+'/src/main.jsx','utf8');
const between=(a,b)=>source.slice(source.indexOf('function '+a+'('),source.indexOf('function '+b+'('));
const modal=between('VehicleSwapModal','RentalAmendmentModal');
const notice=between('RentalAvailabilityNotice','AdminRentalExtensionModal');
const dates=between('formatEasternDateTimeInput','bookingProviderLabel');
const focus=source.slice(source.indexOf('function useDialogFocus('),source.indexOf('class PortalErrorBoundary'));
await writeFile(folder+'/index.html','<meta name="viewport" content="width=device-width, initial-scale=1"><div id="root"></div><script type="module" src="./test.jsx"></script>');
await writeFile(folder+'/test.jsx',`import React,{useState,useEffect,useRef} from 'react';import {createRoot} from 'react-dom/client';import {Car,X} from 'lucide-react';
import {useTaskDraft,DraftOwnerContext} from '../src/useTaskDraft.js';import {trackTaskDialog} from '../src/lib/taskDraft.js';
import {useVehicleAvailability} from '../src/useVehicleAvailability.js';import {swapTimeMessage,swapAvailabilityLabel} from '../src/lib/rentalSwapTime.js';
import '../src/styles.css';import '../src/final-overrides.css';
const money=n=>'$'+Number(n||0).toFixed(2),MONEY_MAX=100000;
const formatRentalDate=(d,t)=>d+' '+t,formatEasternDateTime=v=>v||'',parseBookingDateTime=(d,t)=>new Date(d+'T'+t+'Z');
const day=offset=>new Date(Date.now()+offset*86400000).toISOString().slice(0,10);
window.failAvailability=location.search.includes('fail');window.calls=[];
const supabase={rpc:async(name,args)=>{if(name==='admin_rental_change_context')return{data:{daily_rate:69}};window.calls.push({name,args});if(window.failAvailability) return{error:{message:'Availability service unavailable'}};return{data:[{vehicle_id:'replacement',available:true,conflicts:[]}]}}};
${dates}\n${focus}\n${notice}\n${modal}
function App(){const [closed,setClosed]=useState(false);return closed?<p role="status">Swap saved</p>:<VehicleSwapModal rental={{id:'swap-test',vehicle_id:'old',pickup_date:day(-2),pickup_time:'01:00:00',return_date:day(location.search.includes('overdue')?-1:2),return_time:'23:00:00'}} vehicles={[{id:'replacement',name:'Replacement Audi',daily_rate:69}]} onCancel={()=>setClosed(true)} onExtend={()=>{window.extended=true}} onPreview={async(r,form)=>{window.previewForm=form;return{revision:'rev',periods:[],previous_balance:0,total_delta:0,balance_due:0,deposit_held:300}}} onApply={async(r,form)=>{window.savedForm=form;return true}}/>};
createRoot(document.getElementById('root')).render(<DraftOwnerContext.Provider value="staff"><App/></DraftOwnerContext.Provider>);`);
const server=spawn(process.execPath,[root+'/node_modules/vite/bin/vite.js','--host','127.0.0.1','--port','5198','--strictPort'],{cwd:root,stdio:['ignore','pipe','pipe']});
let browser;
try{
 await new Promise((ready,reject)=>{server.stdout.on('data',d=>{if(d.toString().includes('Local:'))ready()});server.on('error',reject);server.on('exit',()=>reject(Error('Vite exited')))});
 browser=await chromium.launch({headless:true,channel:'chrome'});
 const url='http://127.0.0.1:5198/'+folder.split('/').at(-1)+'/index.html';
 for(const mobile of [false,true]){
  const context=await browser.newContext({viewport:mobile?{width:390,height:720}:{width:1280,height:900}});
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(url+'?fail=1');
  await page.getByLabel('Replacement vehicle').selectOption('replacement');
  await page.getByRole('alert').filter({hasText:'Availability service unavailable'}).waitFor();
  assert.equal(await page.getByLabel('When are the vehicles being exchanged?').inputValue(),'now');
  assert.equal(await page.locator('input[type="datetime-local"]').count(),0);
  assert.equal(await page.getByRole('button',{name:'Review swap',exact:true}).isDisabled(),true);
  assert.equal(await page.getByLabel('Replacement vehicle').locator('option[value="replacement"]').isDisabled(),false);
  assert.equal((await page.locator('body').innerText()).includes('Choose swap time first'),false);
  await page.evaluate(()=>{window.failAvailability=false});
  await page.getByRole('button',{name:'Retry availability',exact:true}).click();
  await page.getByText('Available for these dates',{exact:true}).waitFor();
  await page.getByLabel('Reason and agreement details').fill('Maintenance replacement requested');
  await page.getByRole('button',{name:'Review swap',exact:true}).click();
  await page.getByRole('button',{name:'Confirm swap',exact:true}).waitFor();
  const effective=await page.evaluate(()=>window.previewForm.effectiveAt);
  assert.match(effective,/T\d\d:\d\d:\d\d$/);
  await page.getByRole('button',{name:'Confirm swap',exact:true}).click();
  await page.getByRole('status').filter({hasText:'Swap saved'}).waitFor();
  assert.equal(await page.evaluate(()=>window.savedForm.effectiveAt),effective);
  // A newly opened normal swap ignores the previous now timestamp.
  await page.goto(url);await page.getByText('Choose a replacement vehicle to see its availability or why it is blocked.').waitFor();
  await page.getByLabel('When are the vehicles being exchanged?').selectOption('custom');
  const custom=await page.getByLabel('Actual swap time (Eastern)').inputValue();
  await page.getByLabel('Actual swap time (Eastern)').fill(custom.slice(0,16)+':05');
  await page.getByLabel('Replacement vehicle').selectOption('replacement');
  await page.getByText('Available for these dates',{exact:true}).waitFor();
  await page.reload();assert.equal(await page.getByLabel('When are the vehicles being exchanged?').inputValue(),'custom');
  assert.equal(await page.getByLabel('Actual swap time (Eastern)').inputValue(),custom.slice(0,16)+':05');
  await page.getByLabel('When are the vehicles being exchanged?').selectOption('now');
  await page.goto(url+'?overdue=1');
  await page.getByRole('alert').filter({hasText:'Update the return date first'}).waitFor();
  assert.equal(await page.evaluate(()=>window.calls.length),0);
  await page.getByLabel('Replacement vehicle').selectOption('replacement');
  await page.screenshot({path:'/tmp/rentme-williams-fix-20261105/swap-'+(mobile?'mobile':'desktop')+'.png',fullPage:true});
  await page.getByRole('button',{name:'Update return date'}).click();assert.equal(await page.evaluate(()=>window.extended),true);
  assert.deepEqual(errors,[]);await context.close();
 }
 console.log('PASS: desktop/mobile Swap now, selectable cars during failed checks, retry, preview/confirm same timestamp, custom seconds/draft recovery and overdue return guidance.');
}finally{await browser?.close();server.kill('SIGTERM');await rm(folder,{recursive:true,force:true});}
