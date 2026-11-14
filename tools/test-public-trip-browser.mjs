import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const server=spawn('python3',['-m','http.server','5199','--bind','127.0.0.1'],{stdio:'ignore'});
let browser;
try {
 for(let i=0;i<50;i++){try{await fetch('http://127.0.0.1:5199');break}catch{await new Promise(r=>setTimeout(r,100))}}
 browser=await chromium.launch({headless:true,channel:process.env.PLAYWRIGHT_CHANNEL==='chromium'?undefined:process.env.PLAYWRIGHT_CHANNEL||'chrome'});
 for(const viewport of [{width:1440,height:1000},{width:390,height:844}])for(const timezoneId of ['America/Los_Angeles','Asia/Tokyo']) {
  const context=await browser.newContext({viewport,timezoneId});
  await context.route('https://**/*',async route=>{
   const url=route.request().url();let data=[];
   if(url.includes('get_public_booking_policy'))data={minimum_rental_days:1,minimum_rental_hours:24,advance_notice_minutes:0,server_now:'2026-11-14T17:00:00Z'};
   else if(url.includes('/vehicles?'))data=[{id:'synthetic-car',name:'Test Car',daily_rate:79,security_deposit:300,published:true,status:'available',image_urls:[]}];
   else if(url.includes('get_booking_quote'))data={valid:true,billed_days:1,rental_total:79,tax_amount:5,security_deposit:300,total_due:384};
   else if(url.includes('get_admin_calendar_fleet_availability'))data=[{vehicle_id:'synthetic-car',available:true}];
   await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
  });
  const page=await context.newPage();await page.clock.setFixedTime(new Date('2026-11-14T17:00:00Z'));
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.addInitScript(()=>{localStorage.setItem('rentmect_pending_booking',JSON.stringify({pickupDate:'2099-01-01',returnDate:'2099-01-06',pickupTime:'5:00 PM'}));});
  const assertTrip=async(prefix='')=>{
   for(const [key,value] of Object.entries({pickupDate:'2026-11-15',returnDate:'2026-11-16',pickupTime:'9:00 AM',returnTime:'9:00 AM'})){
    const id=prefix?prefix+key[0].toUpperCase()+key.slice(1):key;
    await page.waitForFunction(({id,value})=>document.getElementById(id)?.value===value,{id,value});
   }
  };
  await page.goto('http://127.0.0.1:5199/index.html?pickupDate=2099-01-01');await assertTrip();
  // Use underlying native date input, exactly as the picker dispatches a change.
  await page.locator('#pickupDate').evaluate(el=>{el.value='2026-11-14';el.dispatchEvent(new Event('change',{bubbles:true}));});
  await page.selectOption('#pickupTime','4:00 PM');
  await page.locator('.availability-form').evaluate(el=>el.requestSubmit());
  await page.waitForURL('**/cars-2.html*');
  await page.waitForFunction(()=>document.getElementById('cars2PickupDate')?.value==='2026-11-14');
  assert.equal(await page.inputValue('#cars2PickupTime'),'4:00 PM');
  assert.equal(new URL(page.url()).searchParams.has('pickupDate'),false);
  await page.reload();await assertTrip('cars2');
  await page.locator('#cars2PickupDate').evaluate(el=>{el.value='2026-11-20';el.dispatchEvent(new Event('change',{bubbles:true}));});
  await page.goto('http://127.0.0.1:5199/contact.html');await page.goBack();await assertTrip('cars2');
  // Exercise persisted restoration even where browser automation disables BFCache.
  await page.locator('#cars2PickupDate').evaluate(el=>{el.value='2026-11-20';el.dispatchEvent(new Event('change',{bubbles:true}));});
  await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));await assertTrip('cars2');
  assert.deepEqual(errors,[]);await context.close();
 }
 console.log('PASS desktop/mobile and two visitor timezones: fresh defaults, stale storage/URL, manual today, one-use handoff, reload, leave/back and BFCache reset.');
} finally {await browser?.close();server.kill();}
