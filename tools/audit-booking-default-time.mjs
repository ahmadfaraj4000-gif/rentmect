import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const shared=fs.readFileSync(new URL('../script.js',import.meta.url),'utf8');
const context={window:{},Date,Intl,Object,Number,JSON,URL};
const session=new Map(),local=new Map();
context.window.sessionStorage={getItem:k=>session.get(k),setItem:(k,v)=>session.set(k,v),removeItem:k=>session.delete(k)};
context.window.localStorage={removeItem:k=>local.delete(k)};
context.window.crypto={randomUUID:()=> 'one-use-token'};
context.window.history={replaceState:()=>{}};
vm.runInNewContext(shared.slice(0,shared.indexOf('let selectedVehicleName')),context);
const api=context.window.RentMePublicTrip;
for(const [instant,pickup,ret] of [
 ['2026-11-14T05:00:00Z','2026-11-15','2026-11-16'],
 ['2026-11-15T04:59:59Z','2026-11-15','2026-11-16'],
 ['2026-12-31T23:00:00Z','2027-01-01','2027-01-02'],
 ['2028-02-28T17:00:00Z','2028-02-29','2028-03-01'],
 ['2026-03-07T17:00:00Z','2026-03-08','2026-03-09'],
 ['2026-10-31T17:00:00Z','2026-11-01','2026-11-02'],
 ['2026-08-06T04:55:00Z','2026-08-07','2026-08-08'],
 ['2026-08-07T03:59:59Z','2026-08-07','2026-08-08'],
]) {
 const trip=api.defaults(new Date(instant));
 assert.equal(trip.pickupDate,pickup);assert.equal(trip.returnDate,ret);
 assert.equal(trip.pickupTime,'9:00 AM');assert.equal(trip.returnTime,'9:00 AM');
}
for(const key of ['rentmect_pending_booking','rentMeCtBooking','pendingBooking','rentmect_period'])local.set(key,'old dates');
let stale=new URL('https://rentmect.com/cars-2.html?pickupDate=2099-01-01&pickupTime=4:00%20PM&vehicle=abc');
assert.equal(api.consumeHandoff(stale),null);assert.equal(stale.searchParams.has('pickupDate'),false);assert.equal(stale.searchParams.get('vehicle'),'abc');assert.equal(local.size,0);
let target=api.createHandoff(new URL('https://rentmect.com/cars-2.html?pickupDate=2026-11-14&pickupTime=4:00%20PM'));
const replay=new URL(target);
assert.equal(api.consumeHandoff(target).pickupDate,'2026-11-14');assert.equal(session.size,0);assert.equal(api.consumeHandoff(replay),null);
context.window.sessionStorage.setItem('rentmect:public-trip-handoff:v1',JSON.stringify({token:'old',expires:0}));
assert.equal(api.consumeHandoff(new URL('https://rentmect.com/cars-2.html?tripHandoff=old&pickupDate=2000-01-01')),null);
const cars=fs.readFileSync(new URL('../cars-2.js',import.meta.url),'utf8');
assert.ok(cars.includes('event.persisted'));assert.ok(shared.includes('event.persisted'));
assert.ok(cars.includes('window.RentMePublicTrip.defaults'));assert.ok(shared.includes('window.RentMePublicTrip.defaults'));
assert.ok(!shared.includes('localStorage.setItem("rentmect_pending_booking"'));
console.log('PASS: Eastern next-day 9 AM defaults, calendar/DST boundaries, stale storage/URLs ignored, one-use handoff and replay/expiry protections.');
