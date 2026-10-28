import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../cars-2.js', import.meta.url), 'utf8');
function harness() {
  const nodes = new Map();
  const element = () => ({ value: '', hidden: true, textContent: '', innerHTML: '', children: [],
    classList: { add() {}, remove() {}, toggle() {} }, setAttribute() {},
    append(child) { this.children.push(child); }, addEventListener(event, callback) { this[event] = callback; } });
  const context = vm.createContext({
    URL, URLSearchParams, Intl, Date, console, AbortController, setTimeout, clearTimeout,
    window: { location: { href: 'https://rentmect.com/cars-2.html', hostname: 'rentmect.com' }, setTimeout, clearTimeout },
    history: { replaceState() {} },
    document: { addEventListener() {}, createElement: element, getElementById(id) {
      if (!nodes.has(id)) nodes.set(id, element());
      return nodes.get(id);
    } },
  });
  vm.runInContext(source.replace(/\}\)\(\);\s*$/, `
    globalThis.app = { state, elements, cacheElements, checkAvailability, renderVehicles, vehicleCard,
      setApi(fn) { apiFetch = fn; } };
  })();`), context);
  const app = context.app;
  app.cacheElements();
  app.state.loading = false;
  app.state.trip = { pickupDate: '2099-10-28', returnDate: '2099-10-29', pickupTime: '9:00 AM', returnTime: '9:00 AM' };
  app.state.vehicles = [{id:'blocked',name:'Blocked car',daily_rate:50},{id:'free',name:'Free car',daily_rate:75}];
  return app;
}
const json = (data) => ({json:async()=>data});
const availability = [{vehicle_id:'blocked',available:false,reason:'Reserved'}, {vehicle_id:'free',available:true}];

test('invalid pickup shows actionable validation, not a sold-out fleet, even with Available only', async () => {
  const app=harness(); app.state.availableOnly=true;
  app.setApi(async () => json({valid:false,error:'The earliest available pickup is tomorrow.'}));
  assert.equal(await app.checkAvailability(),false);
  assert.match(app.elements.cars2Error.textContent,/earliest available pickup/);
  assert.equal(app.elements.cars2Error.hidden,false);
  assert.equal(app.elements.cars2Error.children[0].textContent,'Use next valid pickup time');
  assert.match(app.elements.cars2Grid.innerHTML,/Not checked/);
  assert.doesNotMatch(app.elements.cars2Grid.innerHTML,/>Unavailable</);
  assert.doesNotMatch(app.elements.cars2Grid.innerHTML,/No vehicles match/);
});

test('successful results put bookable cars first while preserving real blocks', async () => {
  const app=harness();
  app.setApi(async (path)=>json(path.endsWith('get_booking_quote')?{valid:true}:availability));
  assert.equal(await app.checkAvailability(),true);
  const html=app.elements.cars2Grid.innerHTML;
  assert.ok(html.indexOf('Free car')<html.indexOf('Blocked car'));
  assert.match(html,/>Unavailable</);
  assert.match(html,/View & book/);
  assert.equal(app.elements.cars2Status.textContent,'1 available for your dates · 2 vehicles shown');
});

test('network errors and incomplete responses stay unverified and provide retry', async () => {
  for (const failure of ['network','missing']) {
    const app=harness();
    app.setApi(async(path)=>{
      if(failure==='network') throw new Error('Failed to fetch');
      return json(path.endsWith('get_booking_quote')?{valid:true}:[]);
    });
    assert.equal(await app.checkAvailability(),false);
    assert.match(app.elements.cars2Grid.innerHTML,/Not checked/);
    assert.doesNotMatch(app.elements.cars2Grid.innerHTML,/>Unavailable</);
    assert.equal(app.elements.cars2Error.children[0].textContent,'Try availability again');
  }
});

test('older quote responses cannot erase a newer valid availability result', async () => {
  const app=harness(); let resolveOld; let quotes=0;
  app.setApi(async(path)=>{
    if(path.endsWith('get_booking_quote')) {
      if(++quotes===1) return new Promise(resolve=>{resolveOld=resolve;});
      return json({valid:true});
    }
    return json(availability);
  });
  const old=app.checkAvailability();
  await app.checkAvailability();
  resolveOld(json({valid:false,error:'Old invalid dates'}));
  await old;
  assert.equal(app.state.availability.get('free').available,true);
  assert.equal(app.state.availabilityError,'');
});

test('locally invalid dates invalidate an in-flight valid request and show a visible error', async () => {
  const app=harness(); let resolveOld;
  app.setApi(async()=>new Promise(resolve=>{resolveOld=resolve;}));
  const old=app.checkAvailability();
  app.state.trip.returnDate=app.state.trip.pickupDate;
  assert.equal(await app.checkAvailability(),false);
  resolveOld(json({valid:true})); await old;
  assert.equal(app.state.availability.size,0);
  assert.equal(app.elements.cars2Error.hidden,false);
  assert.match(app.elements.cars2Grid.innerHTML,/Not checked/);
});

test('recovery picks a server-based future slot and rechecks without starting checkout', async () => {
  const app=harness(); const paths=[];
  app.setApi(async(path)=>{ paths.push(path); return json({valid:false,error:'Pickup has passed'}); });
  await app.checkAvailability();
  app.setApi(async(path)=>{
    paths.push(path);
    if(path.endsWith('get_public_booking_policy')) return json([{server_now:'2099-10-28T16:00:00Z',minimum_rental_days:1,minimum_rental_hours:24,advance_notice_minutes:60}]);
    return json(path.endsWith('get_booking_quote')?{valid:true}:availability);
  });
  await app.elements.cars2Error.children[0].click();
  assert.equal(app.state.trip.pickupTime,'3:00 PM');
  assert.equal(app.state.trip.returnTime,'3:00 PM');
  assert.equal(app.state.trip.returnDate,'2099-10-29');
  assert.equal(app.state.availability.get('free').available,true);
  assert.equal(app.elements.cars2Error.hidden,true);
  assert.ok(paths.every(path=>/get_public_booking_policy|get_booking_quote|get_admin_calendar_fleet_availability/.test(path)));
});
