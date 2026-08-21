import fs from 'node:fs';

const read = (file) => fs.readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
const requireText = (source, text, label) => {
  if (!source.includes(text)) throw new Error(label);
};

const browser = read('cars-2.js');
const edge = read('supabase/functions/website-booking-hold/index.ts');
const migration = read('supabase/migrations/20260820233000_protect_public_booking_holds.sql');
const closeout = read('supabase/migrations/20260820234500_close_legacy_booking_hold_rpcs.sql');
const config = read('supabase/config.toml');

requireText(browser, '/functions/v1/website-booking-hold', 'Cars-2 must create holds through the protected Edge Function.');
requireText(browser, '"X-RentMe-Device": bookingDeviceId()', 'Cars-2 must send its anonymous device limiter.');
if (browser.includes('/rest/v1/rpc/create_website_pending_booking_with_token')) {
  throw new Error('Cars-2 must not call the legacy anonymous hold RPC.');
}

for (const origin of ['https://rentmect.com', 'https://www.rentmect.com', 'https://login.rentmect.com']) {
  requireText(edge, origin, `Protected hold CORS must allow ${origin}.`);
}
if (edge.includes('"Access-Control-Allow-Origin": "*"')) {
  throw new Error('Protected hold CORS must never use a wildcard origin.');
}
requireText(edge, 'const browserKey = request.headers.get("apikey")', 'Protected hold endpoint must require a browser API key header.');
requireText(edge, 'hmacHex(serviceRoleKey', 'Network and device identifiers must be HMAC protected.');
requireText(edge, 'create_rate_limited_website_booking_hold', 'Edge Function must call the service-only rate-limited RPC.');
requireText(edge, 'booking_id: result.booking_id', 'Edge Function must return only the booking handoff fields.');

for (const guard of [
  "coalesce(published, false)",
  "coalesce(is_active, true)",
  "p_pickup_date > v_local_today + 365",
  "p_return_date > p_pickup_date + 180",
  "v_ip_active_holds >= 6",
  "v_device_active_holds >= 3",
]) {
  requireText(migration, guard, `Missing booking-hold guard: ${guard}`);
}
requireText(migration, 'to service_role;', 'Protected hold RPC must be service-role only.');
requireText(closeout, 'from public, anon, authenticated;', 'Legacy hold RPCs must be revoked after rollout.');
requireText(config, '[functions.website-booking-hold]', 'Protected Edge Function must be present in Supabase config.');
if (config.includes('[functions.wheelbase-availability]')) {
  throw new Error('Removed Wheelbase relay must not remain configured.');
}
if (fs.existsSync(new URL('../supabase/functions/wheelbase-availability/index.ts', import.meta.url))) {
  throw new Error('Removed Wheelbase relay source must not remain deployable.');
}

console.log('PASS Booking hold protections and Wheelbase relay removal are encoded in source.');
