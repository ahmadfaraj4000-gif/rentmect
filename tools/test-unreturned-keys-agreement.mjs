import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { AGREEMENT_TEXT, AGREEMENT_VERSION } from '../rentmect-client-portal/src/rentalAgreement.js';
import { AGREEMENT_TEXT as adminText, AGREEMENT_VERSION as adminVersion } from '../rentmect-admin-portal/src/rentalAgreement.js';

const read = path => readFileSync(new URL('../' + path, import.meta.url), 'utf8');
const clause = `UNRETURNED KEYS AND KEY FOBS
Renter must return all keys and key fobs provided with the Vehicle at the end of the rental. If any key or key fob is not returned, Renter shall be responsible for the actual, reasonable cost of replacement, including necessary cutting, programming, and deactivation of missing keys or key fobs, plus a service fee of two hundred dollars ($200), to the extent permitted by law.
Renter shall also be responsible for documented rental income lost directly because the missing key or key fob makes the Vehicle unavailable for rental, limited to the reasonable time necessary to restore the Vehicle to rental service and any limits imposed by applicable law. Company shall take reasonable steps to minimize this loss and shall not collect duplicate compensation for the same period or expense. Company may deduct authorized amounts from the security deposit or charge the payment method on file, with an itemized statement provided to Renter.`;

test('both signing agreements and all three public pages contain the exact requested clause', () => {
  assert.equal(AGREEMENT_VERSION, 'rentmect-master-v2026-10-23-unreturned-keys-r1');
  assert.equal(adminVersion, AGREEMENT_VERSION);
  assert.equal(adminText, AGREEMENT_TEXT);
  assert.ok(AGREEMENT_TEXT.includes(clause));
  assert.equal(AGREEMENT_TEXT.split(clause).length, 2);
  for (const file of ['agreement.html', 'terms.html', 'rental-policies.html']) {
    const html = read(file);
    for (const line of clause.split('\n')) assert.ok(html.includes(line), file);
    assert.match(html, /Last updated October 23, 2026/);
  }
  const migration = read('supabase/migrations/20261023220000_unreturned_keys_agreement.sql');
  assert.ok(migration.includes(AGREEMENT_VERSION));
  assert.ok(migration.includes(clause));
});

test('unsigned admin agreements ignore stale snapshots; signed records retain their original text', () => {
  const source = read('rentmect-admin-portal/src/main.jsx');
  const signedDeclaration = source.match(/const alreadySigned = scope === 'agreement'[^;]+;/)[0];
  const displayDeclaration = source.match(/const displayedAgreement = alreadySigned[^;]+;/)[0];
  for (const signed of [false, true]) {
    const result = vm.runInNewContext(`${signedDeclaration}\n${displayDeclaration}\ndisplayedAgreement`, {
      scope: 'agreement', rental: { agreement_signed: signed, agreement_snapshot: 'Historical signed terms' }, AGREEMENT_TEXT,
    });
    assert.equal(result, signed ? 'Historical signed terms' : AGREEMENT_TEXT);
  }
});
