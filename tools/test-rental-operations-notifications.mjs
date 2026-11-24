// Exercise the notification worker with a synthetic recipient and a local transport.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
const source = await readFile(new URL('../supabase/functions/notify-admin-events/index.ts', import.meta.url), 'utf8');
const worker = stripTypeScriptTypes(source.replace(/^import .*?;$/m, ''));
const env = { PUSHOVER_APP_TOKEN: 'test-app', PUSHOVER_USER_KEY: 'ordinary-admin', PUSHOVER_RENTAL_OPERATIONS_GROUP: 'two-staff', RENTMECT_ADMIN_PORTAL_URL: 'https://example.invalid/admin' };
const sent = [];
const sandbox = vm.createContext({URL, URLSearchParams, Intl, createClient: () => ({}),
  Deno: {env: {get: k => env[k]}, serve() {}},
  fetch: async (url, {body}) => { sent.push(Object.fromEntries(body)); return {ok:true, json:async()=>({status:1,request:'test-id'})}; }
});
vm.runInContext(worker,sandbox);
for (const event_type of ['customer_message_received','online_customer_steps_complete']) {
  await sandbox.deliver({event_type,metadata:{notification_test:true}});
}
assert.equal(sent.length,2);
assert.ok(sent.every(x=>x.user==='two-staff' && x.title.startsWith('[TEST]')));
assert.equal(new URL(sent[0].url).searchParams.get('tab'),'emails');
assert.match(sent[1].message,/Prepare the car, take pickup photos, and inspect insurance/);
console.log('Passed both synthetic Pushover event paths with local transport.');
