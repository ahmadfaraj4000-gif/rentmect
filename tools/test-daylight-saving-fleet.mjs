import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../cars-2.js',import.meta.url),'utf8');
const code=source.slice(source.indexOf('  function validDateParam('),source.indexOf('  function earliestPickupSlot('));
test('public fleet quote fallback uses the same Eastern rental days as server',()=>{
 const state={trip:{pickupDate:'2026-10-30',returnDate:'2026-11-01',pickupTime:'6:00 PM',returnTime:'6:00 PM'}};
 const days=vm.runInNewContext(`${code}\nrentalDays`,{state,Intl,Date,TIME_OPTIONS:['6:00 PM','6:01 PM']});
 assert.equal(days(),2);
 state.trip.returnTime='6:01 PM';assert.equal(days(),3);
 state.trip={pickupDate:'2027-03-13',returnDate:'2027-03-14',pickupTime:'6:00 PM',returnTime:'6:00 PM'};
 assert.equal(days(),1);
 state.trip.returnTime='6:01 PM';assert.equal(days(),2);
});
