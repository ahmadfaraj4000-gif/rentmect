import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { AGREEMENT_TEXT, AGREEMENT_VERSION } from '../rentmect-client-portal/src/rentalAgreement.js';
import { AGREEMENT_TEXT as adminText, AGREEMENT_VERSION as adminVersion } from '../rentmect-admin-portal/src/rentalAgreement.js';
const source = readFileSync(new URL('../rentmect-client-portal/src/main.jsx', import.meta.url), 'utf8');
test('customer, admin and public pages publish both exact new clauses', () => {
  assert.equal(AGREEMENT_TEXT, adminText);
  assert.equal(AGREEMENT_VERSION, adminVersion);
  const clauses = AGREEMENT_TEXT.split('SECURITY DEPOSIT HOLD AND POST-RENTAL TICKET CHARGES\n')[1].split('\n\n')[0].split('\n');
  assert.equal(clauses.length, 2);
  for (const file of ['agreement.html', 'terms.html', 'rental-policies.html']) {
    const page = readFileSync(new URL('../' + file, import.meta.url), 'utf8');
    for (const clause of clauses) assert.ok(page.includes(clause), file);
  }
  assert.match(clauses[0], /thirty \(30\) calendar days/);
  assert.match(clauses[1], /one \(1\) year/);
  assert.match(clauses[1], /no amount shall be collected twice/);
});
function restoreFixture(blockStorage = false) {
  let form = { pickupDate: '2026-10-22', returnDate: '2026-10-23' };
  const context = vm.createContext({ setCheckoutIntent() {}, setCheckoutExpiresAt() {}, setPendingVehicleName() {}, setPendingVehicleId() {},
    setReservationForm: fn => { form = fn(form); }, localStorage: { setItem() { if (blockStorage) throw Error('Storage blocked'); } } });
  vm.runInContext(source.slice(source.indexOf('  function applyBookingDataToPortal('), source.indexOf('  async function loadPendingBookingFromDatabase(')), context);
  return { restore: context.applyBookingDataToPortal, get: () => form };
}
for (const [label, dates] of [
  ['ongoing rental with past pickup', ['2026-10-18', '2026-10-25']],
  ['future reservation', ['2026-11-03', '2026-11-08']],
  ['same-day admin reservation', ['2026-10-22', '2026-10-22']],
]) test(`refresh preserves ${label}`, () => {
  const f = restoreFixture();
  f.restore({ pickup_date: dates[0], return_date: dates[1], pickup_time: '2:30 PM', return_time: '5:00 PM' });
  assert.equal(f.get().pickupDate, dates[0]); assert.equal(f.get().returnDate, dates[1]);
  assert.equal(f.get().pickupTime, '2:30 PM'); assert.equal(f.get().returnTime, '5:00 PM');
});
test('blocked browser storage does not lose the restored dates', () => {
  const f = restoreFixture(true); f.restore({ pickupDate: '2026-11-03', returnDate: '2026-11-08' });
  assert.equal(f.get().pickupDate, '2026-11-03');
});
test('empty metadata cannot synthesize a booking for today', () => {
  const f = restoreFixture(); f.restore({}); assert.deepEqual(f.get(), { pickupDate: '2026-10-22', returnDate: '2026-10-23' });
});
function signingFixture({ rpcError = null, reloadError = null, createError = null } = {}) {
  const calls = []; let signed = [];
  const rental = { id: 'rental', pickup_date: '2026-10-18', return_date: '2026-10-25', pickup_time: '2:30 PM', return_time: '5:00 PM', vehicles: {} };
  const context = vm.createContext({ agreementSaving: false, setAgreementError: value => calls.push(['error', value]), session: { user: { id: 'user' } },
    currentRental: createError ? null : rental, createReservationIfNeeded: async () => { throw createError; },
    agreementChecked: true, signatureName: 'Test Renter', signatureImageData: 'data:image/png;base64,test',
    setAgreementSaving: value => calls.push(['saving', value]), buildAgreementWithDetails: details => { calls.push(['details', details]); return 'snapshot'; },
    AGREEMENT_TEXT, AGREEMENT_VERSION, profileForm: {}, userEmail: 'test@example.invalid', selectedVehicle: null,
    reservationForm: { pickupDate: '2026-10-22', returnDate: '2026-10-23' }, approvedUnpaidExtension: null, currentAccount: null, vehicles: [],
    sha256: async () => 'hash', navigator: { userAgent: 'test' },
    supabase: { rpc: async () => ({ data: { ...rental, agreement_signed: true }, error: rpcError }), from: () => ({ select() { return this; }, eq() { return this; }, single: async () => ({ data: reloadError ? null : { ...rental, agreement_signed: true }, error: reloadError }) }) },
    setRentals: fn => { signed = fn([]); }, setAgreementModalOpen: value => calls.push(['open', value]), setWizardReminder() {}, setPreviewCheckoutSection() {},
    wizardOpen: false, setWizardStep() {}, setActiveTab() {}, notify() {}, maybeMarkReadyForPickup: async () => {}, customerSafeMessage: s => s, console: { error() {}, warn() {} },
  });
  vm.runInContext(source.slice(source.indexOf('  async function signAgreement()'), source.indexOf('  async function sendSupportMessage(')), context);
  return { run: context.signAgreement, calls, signed: () => signed };
}
test('signing snapshots saved rental dates instead of the initial today defaults', async () => {
  const f = signingFixture(); await f.run();
  const details = f.calls.find(c => c[0] === 'details')[1];
  assert.equal(details.reservation.pickupDate, '2026-10-18'); assert.equal(details.reservation.returnDate, '2026-10-25');
});
test('successful signature stays successful if the follow-up read fails', async () => {
  const f = signingFixture({ reloadError: Error('Network read failed') }); await f.run();
  assert.equal(f.signed()[0].agreement_signed, true); assert.ok(f.calls.some(c => c[0] === 'open' && c[1] === false));
});
for (const options of [{ rpcError: Error('Signing service unavailable') }, { createError: Error('Reservation unavailable') }]) test('signing failure remains visible and clears the saving state', async () => {
  const f = signingFixture(options); await f.run();
  assert.ok(f.calls.some(c => c[0] === 'error' && c[1])); assert.deepEqual(f.calls.at(-1), ['saving', false]);
  assert.equal(f.signed().length, 0);
});
