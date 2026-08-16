import fs from 'node:fs';
import vm from 'node:vm';

const read = (file) => fs.readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');

function functionSource(source, name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`Missing ${name}`);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    if (source[index] === '}') depth -= 1;
    if (depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`Unbalanced ${name}`);
}

function constantSource(source, name) {
  const match = source.match(new RegExp(`const ${name} = [^;]+;`));
  if (!match) throw new Error(`Missing ${name}`);
  return match[0];
}

const constants = [
  'RENT_ME_CT_TIME_ZONE',
  'RENTAL_OPENING_MINUTES',
  'RENTAL_LAST_SLOT_MINUTES',
  'RENTAL_DEFAULT_NOTICE_MINUTES',
  'RENTAL_SLOT_MINUTES',
];
const cases = [
  ['12:55 AM ET opens at 9:00 AM', '2026-08-06T04:55:00Z', { date: '2026-08-06', time: '9:00 AM' }],
  ['8:59 AM ET opens at 9:00 AM', '2026-08-06T12:59:00Z', { date: '2026-08-06', time: '9:00 AM' }],
  ['9:00 AM ET adds three hours', '2026-08-06T13:00:00Z', { date: '2026-08-06', time: '12:00 PM' }],
  ['9:01 AM ET rounds to the next half-hour', '2026-08-06T13:01:00Z', { date: '2026-08-06', time: '12:30 PM' }],
  ['12:55 PM ET becomes 4:00 PM', '2026-08-06T16:55:00Z', { date: '2026-08-06', time: '4:00 PM' }],
  ['8:31 PM ET rolls overnight to 9:00 AM', '2026-08-07T00:31:00Z', { date: '2026-08-07', time: '9:00 AM' }],
  ['Winter midnight still uses Eastern Time', '2026-12-15T05:55:00Z', { date: '2026-12-15', time: '9:00 AM' }],
];

const shared = read('script.js');
const homepage = read('index.html');
const sharedContext = vm.createContext({ Date, Intl, Math, Number, Object, String });
vm.runInContext([
  ...constants.map((name) => constantSource(shared, name)),
  functionSource(shared, 'getDefaultRentalSlot'),
  functionSource(shared, 'getEasternDateTimeParts'),
  functionSource(shared, 'minutesToRentalTime'),
  functionSource(shared, 'getNextDateInputValue'),
  functionSource(shared, 'getRentalDateTime'),
  'globalThis.calculate = getDefaultRentalSlot;',
  'globalThis.toInstant = getRentalDateTime;',
].join('\n'), sharedContext);

const cars2 = read('cars-2.js');
if (!shared.includes('pickupTimeCustomized: quickBookingPickupTimeCustomized')) {
  throw new Error('Homepage handoff must label a customer-selected pickup time.');
}
if (homepage.includes('function startBooking(')) {
  throw new Error('The homepage must use the single shared booking submit handler.');
}
const homepageStartBooking = functionSource(shared, 'startBooking');
if (!homepageStartBooking.includes('pickupTimeCustomized: quickBookingPickupTimeCustomized')) {
  throw new Error('The visible homepage handler must label a customer-selected pickup time.');
}
if (!homepageStartBooking.includes('returnTimeCustomized: quickBookingReturnTimeCustomized')) {
  throw new Error('The visible homepage handler must label a customer-selected return time.');
}
if (!cars2.includes('const initialPickupTime = requestedPickupTime || "9:00 AM"')) {
  throw new Error('Cars-2 must honor an explicitly handed-off pickup time.');
}
if (!cars2.includes('requestedReturnTimeCustomized && requestedReturnTime')) {
  throw new Error('Cars-2 must ignore an inherited legacy return default unless the customer selected it.');
}
function homepageHandoff(pickupCustomized, returnCustomized) {
  const saved = new Map();
  const controls = {
    pickupDate: { value: '2099-08-06' },
    returnDate: { value: '2099-08-07' },
    pickupTime: { value: '4:00 PM' },
    returnTime: { value: '5:30 PM' },
  };
  const context = vm.createContext({
    Date,
    URLSearchParams,
    quickBookingPickupTimeCustomized: pickupCustomized,
    quickBookingReturnTimeCustomized: returnCustomized,
    document: { getElementById: (id) => controls[id] || null },
    getRentalDateTime: (date) => new Date(`${date}T12:00:00Z`),
    updateQuickBookingSummary: () => {},
    formatDate: (value) => value,
    normalizeRentalTimeInputs: () => {},
    selectedRentalPeriod: '',
    selectedVehicleName: '',
    ACTIVE_BOOKING_PAGE_PATH: 'cars-2.html',
    localStorage: {
      getItem: () => '',
      setItem: (key, value) => saved.set(key, value),
    },
    window: {
      getActiveBookingPage: () => 'cars-2.html',
      location: { href: '' },
    },
  });
  vm.runInContext(`${homepageStartBooking}\nglobalThis.submitHomepage = startBooking;`, context);
  context.submitHomepage({ preventDefault() {} });
  return {
    stored: JSON.parse(saved.get('rentmect_pending_booking')),
    destination: new URL(context.window.location.href, 'https://rentmect.com/'),
  };
}

const customizedHandoff = homepageHandoff(true, true);
if (customizedHandoff.stored.pickupTimeCustomized !== true || customizedHandoff.stored.returnTimeCustomized !== true) {
  throw new Error('Homepage local storage must preserve both customer-selected time flags.');
}
if (customizedHandoff.destination.searchParams.get('pickupTimeCustomized') !== '1'
  || customizedHandoff.destination.searchParams.get('returnTimeCustomized') !== '1') {
  throw new Error('Homepage Cars-2 URL must preserve both customer-selected time flags.');
}
const defaultHandoff = homepageHandoff(false, false);
if (defaultHandoff.destination.searchParams.get('pickupTimeCustomized') !== '0'
  || defaultHandoff.destination.searchParams.get('returnTimeCustomized') !== '0') {
  throw new Error('Untouched homepage defaults must remain explicitly recalculable by Cars-2.');
}

const domReadyStart = shared.indexOf('document.addEventListener("DOMContentLoaded"');
const bookingInitPosition = shared.indexOf('populateTimeSelects();', domReadyStart);
const optionalPromotionPosition = shared.indexOf('setupSitePromotion();', domReadyStart);
if (bookingInitPosition < 0 || optionalPromotionPosition < 0 || bookingInitPosition > optionalPromotionPosition) {
  throw new Error('Critical booking controls must initialize before optional homepage enhancements.');
}
const timeOptionsStart = cars2.indexOf('const TIME_OPTIONS =');
const timeOptionsEnd = cars2.indexOf('  const RENT_ME_CT_TIME_ZONE', timeOptionsStart);
const cars2Context = vm.createContext({ Date, Intl, Math, Number, Object, String });
vm.runInContext([
  cars2.slice(timeOptionsStart, timeOptionsEnd),
  ...constants.map((name) => constantSource(cars2, name)),
  'const state = { policy: { serverNow: "", advanceNoticeMinutes: 0 } };',
  functionSource(cars2, 'addDays'),
  functionSource(cars2, 'earliestPickupSlot'),
  functionSource(cars2, 'easternDateTimeParts'),
  functionSource(cars2, 'minutesToTime'),
  functionSource(cars2, 'timeToMinutes'),
  'globalThis.calculate = (serverNow) => { state.policy.serverNow = serverNow; return earliestPickupSlot(); };',
].join('\n'), cars2Context);

let failures = 0;
for (const [label, instant, expected] of cases) {
  for (const [surface, actual] of [
    ['Homepage', sharedContext.calculate(new Date(instant))],
    ['Cars-2', cars2Context.calculate(instant)],
  ]) {
    const passed = actual.date === expected.date && actual.time === expected.time;
    console.log(`${passed ? 'PASS' : 'FAIL'} ${surface}: ${label} -> ${actual.date} ${actual.time}`);
    if (!passed) failures += 1;
  }
}

if (failures) process.exit(1);

const wallClockCases = [
  ['Summer 9:00 AM ET', '2026-08-06', '9:00 AM', '2026-08-06T13:00:00.000Z'],
  ['Winter 9:00 AM ET', '2026-12-15', '9:00 AM', '2026-12-15T14:00:00.000Z'],
  ['Summer 11:30 PM ET', '2026-08-06', '11:30 PM', '2026-08-07T03:30:00.000Z'],
];
for (const [label, date, time, expected] of wallClockCases) {
  const actual = sharedContext.toInstant(date, time).toISOString();
  const passed = actual === expected;
  console.log(`${passed ? 'PASS' : 'FAIL'} ${label} -> ${actual}`);
  if (!passed) failures += 1;
}

if (failures) process.exit(1);
console.log(`\nAll ${cases.length * 2 + wallClockCases.length} Eastern-time booking checks passed.`);
