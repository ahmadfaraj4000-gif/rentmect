import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/migrations/20260806200000_fix_unverified_phone_correction.sql', import.meta.url), 'utf8');

assert.match(migration, /v_phone_normalized text := public\.rentmect_normalize_phone\(v_phone\)/);
assert.match(migration, /v_saved_phone_normalized := public\.rentmect_normalize_phone\(v_profile\.phone\)/);
assert.match(migration, /v_phone_changed := v_saved_phone_normalized is distinct from v_phone_normalized/);
assert.match(migration, /select coalesce\(v_profile\.phone_verified, false\) and exists/);
assert.match(migration, /phone = case when v_phone_changed then v_phone else phone end/);
assert.match(migration, /phone_verified = case when v_phone_changed then false else phone_verified end/);
assert.doesNotMatch(migration, /v_phone_changed := coalesce\(v_profile\.phone, ''\) is distinct from coalesce\(v_phone, ''\)/);

console.log('Phone profile-save normalization and verified-lock guard passed.');
