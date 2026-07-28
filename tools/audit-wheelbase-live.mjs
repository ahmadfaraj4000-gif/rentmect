import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const cars = fs.readFileSync(path.join(root, 'cars.html'), 'utf8');
const rentalIds = [...cars.matchAll(/data-wheelbase-rental-id="(\d+)"/g)].map((match) => match[1]);
const uniqueRentalIds = [...new Set(rentalIds)];

assert(rentalIds.length === 29, `Expected 29 Wheelbase vehicle cards, found ${rentalIds.length}.`);
assert(uniqueRentalIds.length === 29, `Expected 29 unique Wheelbase rental IDs, found ${uniqueRentalIds.length}.`);
assert(cars.includes('const WHEELBASE_OWNER_ID = "4960447"'), 'Wheelbase owner ID is missing or changed.');
assert(cars.includes('const WHEELBASE_ACCOUNT_ID = "4960447"'), 'Wheelbase account ID is missing or changed.');
assert(cars.includes('initializeWheelbaseAvailabilityBridge();'), 'Wheelbase initialization is not called.');
assert(cars.includes('wheelbaseApp.start();'), 'Wheelbase application start is missing.');
assert(cars.includes('window.location.href = buildIndividualRentalCheckoutUrl'), 'Wheelbase checkout handoff is missing.');

const sdkUrl = 'https://d3cuf6g1arkgx6.cloudfront.net/sdk/1-5/wheelbase-widget.min.js';
const rentalApiUrl = `https://api.outdoorsy.co/v0/rentals/${uniqueRentalIds[0]}`;
const availabilityBaseUrl = 'https://gqmiktepthaafupwdmcl.supabase.co/functions/v1/wheelbase-availability';
const checkoutBaseUrl = 'https://checkout.wheelbasepro.com/reserve';
const { from, to } = futureDateRange();

const sdkResponse = await fetch(sdkUrl, { headers: { Accept: 'application/javascript' } });
assert(sdkResponse.ok, `Wheelbase SDK returned HTTP ${sdkResponse.status}.`);
const sdkSource = await sdkResponse.text();
assert(sdkSource.length > 100_000, 'Wheelbase SDK response was unexpectedly small.');

const rentalResponse = await fetch(rentalApiUrl, { headers: { Accept: 'application/json' } });
assert(rentalResponse.ok, `Wheelbase rental API returned HTTP ${rentalResponse.status}.`);
const rental = await rentalResponse.json();
assert(String(rental.id) === uniqueRentalIds[0], 'Wheelbase rental API returned the wrong vehicle.');
assert(String(rental.owner_id) === '4960447', `Wheelbase rental belongs to owner ${rental.owner_id}, not 4960447.`);
assert(rental.published === true, 'Wheelbase sample rental is not published.');

const availabilityUrl = new URL(availabilityBaseUrl);
availabilityUrl.searchParams.set('rental_id', uniqueRentalIds[0]);
availabilityUrl.searchParams.set('from', from);
availabilityUrl.searchParams.set('to', to);
availabilityUrl.searchParams.set('from_time', '32400');
availabilityUrl.searchParams.set('to_time', '32400');
const availabilityResponse = await fetch(availabilityUrl, { headers: { Accept: 'application/json' } });
assert(availabilityResponse.ok, `Wheelbase availability proxy returned HTTP ${availabilityResponse.status}.`);
const availability = await availabilityResponse.json();
assert(typeof availability.available === 'boolean', 'Wheelbase availability proxy did not return a boolean.');
assert(String(availability.rentalId) === uniqueRentalIds[0], 'Wheelbase availability proxy returned the wrong rental.');

const checkoutUrl = new URL(`${checkoutBaseUrl}/${uniqueRentalIds[0]}`);
checkoutUrl.searchParams.set('from', from);
checkoutUrl.searchParams.set('to', to);
checkoutUrl.searchParams.set('from_time', '32400');
checkoutUrl.searchParams.set('to_time', '32400');
const checkoutResponse = await fetch(checkoutUrl, { redirect: 'manual' });
assert(checkoutResponse.ok || (checkoutResponse.status >= 300 && checkoutResponse.status < 400),
  `Wheelbase checkout returned HTTP ${checkoutResponse.status}.`);

console.log(`PASS cars.html contains ${uniqueRentalIds.length} unique Wheelbase rental IDs`);
console.log('PASS Wheelbase SDK is live');
console.log(`PASS Rental ${uniqueRentalIds[0]} is published under Wheelbase owner 4960447`);
console.log(`PASS Live availability proxy returned available=${availability.available} for ${from} to ${to}`);
console.log(`PASS Wheelbase checkout responded with HTTP ${checkoutResponse.status}`);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function futureDateRange() {
  const start = new Date();
  start.setUTCDate(start.getUTCDate() + 2);
  const end = new Date(start);
  end.setUTCDate(end.getUTCDate() + 1);
  return {
    from: start.toISOString().slice(0, 10),
    to: end.toISOString().slice(0, 10),
  };
}
