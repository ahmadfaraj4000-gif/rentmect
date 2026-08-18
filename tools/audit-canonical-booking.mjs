import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const failures = [];
const check = (condition, message) => {
  if (!condition) failures.push(message);
};

const carsHtml = read('cars-2.html');
const carsJs = read('cars-2.js');
const publicScript = read('script.js');
const homepageHtml = read('index.html');
const bookingPickerJs = read('booking-picker.js');
const bookingPickerCss = read('booking-picker.css');

for (const legacyPage of ['cars.html', 'cars-wheelbase.html']) {
  const source = read(legacyPage);
  check(source.length < 2500, `${legacyPage} must remain a redirect-only shell`);
  check(source.includes('name="robots" content="noindex, nofollow"'), `${legacyPage} must be excluded from search`);
  check(source.includes('href="https://rentmect.com/cars-2.html"'), `${legacyPage} must canonicalize to Cars-2`);
  check(source.includes('"cars-2.html" + window.location.search + window.location.hash'), `${legacyPage} must preserve booking query parameters and the hash`);
  check(!/wheelbase-widget|data-wheelbase-rental-id|cars-2\.js|script\.js/i.test(source), `${legacyPage} must never load a booking implementation`);
}

const requiredIdsBlock = carsJs.match(/const REQUIRED_ELEMENT_IDS = \[([\s\S]*?)\];/);
check(Boolean(requiredIdsBlock), 'cars-2.js must declare REQUIRED_ELEMENT_IDS');
const requiredIds = requiredIdsBlock
  ? [...requiredIdsBlock[1].matchAll(/"([A-Za-z0-9_-]+)"/g)].map((match) => match[1])
  : [];
check(requiredIds.length >= 40, 'Cars-2 runtime contract unexpectedly contains too few required elements');

const missingIds = requiredIds.filter((id) => !new RegExp(`id=["']${id}["']`).test(carsHtml));
check(missingIds.length === 0, `cars-2.html is missing JavaScript-required IDs: ${missingIds.join(', ')}`);

const elementReferences = [...carsJs.matchAll(/elements\.([A-Za-z0-9_]+)/g)].map((match) => match[1]);
const unregisteredReferences = [...new Set(elementReferences)].filter((id) => !requiredIds.includes(id));
check(unregisteredReferences.length === 0, `cars-2.js uses unregistered DOM elements: ${unregisteredReferences.join(', ')}`);

check(/href="cars-2\.css\?v=[^"]+"/.test(carsHtml), 'Cars-2 stylesheet must be versioned');
check(/src="cars-2\.js\?v=[^"]+"/.test(carsHtml), 'Cars-2 JavaScript must be versioned');
check(carsJs.includes('renderFatalLoadFailure'), 'Cars-2 must render a customer-safe initialization failure state');
check(carsJs.includes('Request timed out. Please retry this section.'), 'Cars-2 public requests must retain a retryable deadline');

check(publicScript.includes('const ACTIVE_BOOKING_PAGE_PATH = "cars-2.html"'), 'Public routing must be permanently locked to Cars-2');
check(!publicScript.includes('get_public_booking_page_setting'), 'Public routing must not be controlled by the legacy provider setting');
check(!publicScript.includes('setInterval(setupBookingPageRouting'), 'Public routing must not poll for a provider switch');

check(bookingPickerJs.includes('data-calendar-action="close"'), 'The shared date picker must include a mobile close control');
check(bookingPickerJs.includes('booking-calendar-modal-open'), 'The shared date picker must lock background scrolling while open');
check(bookingPickerCss.includes('height: 100dvh'), 'The mobile date picker must fit the visible phone viewport');
check(bookingPickerCss.includes('.booking-calendar-month:nth-child(2)'), 'The mobile date picker must expose the second month');
check(/booking-picker\.css\?v=20260818-from-until-2/.test(homepageHtml), 'Homepage must load the current mobile picker stylesheet');
check(/booking-picker\.js\?v=20260816-mobile-sheet-1/.test(carsHtml), 'Cars-2 must load the current mobile picker JavaScript');

const rootHtmlFiles = fs.readdirSync(root).filter((name) => name.endsWith('.html') && !['cars.html', 'cars-wheelbase.html'].includes(name));
for (const file of rootHtmlFiles) {
  const source = read(file);
  const legacyLinks = [...source.matchAll(/href=["']([^"']*(?:cars\.html|cars-wheelbase\.html)[^"']*)["']/gi)];
  check(legacyLinks.length === 0, `${file} links to a legacy booking page: ${legacyLinks.map((match) => match[1]).join(', ')}`);
}

const promotionBootstrap = read('supabase/site_promotions.sql');
check(!promotionBootstrap.includes("'cars.html'"), 'Promotion bootstrap must not recreate cars.html destinations');

const bookingLock = read('supabase/migrations/20260806194500_lock_public_booking_to_cars2.sql');
check(bookingLock.includes("'cars-2.html'::text"), 'Database booking routing must resolve to Cars-2');
check(bookingLock.includes('Legacy booking pages are disabled'), 'Database must reject legacy provider activation');

if (failures.length) {
  failures.forEach((failure) => console.error(`FAIL ${failure}`));
  process.exit(1);
}

console.log(`PASS Cars-2 DOM contract: ${requiredIds.length} required elements are present`);
console.log('PASS Legacy booking URLs are redirect-only and preserve booking parameters');
console.log('PASS Public and database routing are permanently locked to cars-2.html');
console.log('PASS Public HTML contains no links to legacy booking pages');
console.log('PASS Shared mobile date picker is a viewport-contained sheet');
