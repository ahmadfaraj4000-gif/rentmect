import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../supabase/functions/tollspot-sync/index.ts', import.meta.url), 'utf8');
const handler = source.slice(source.indexOf('async function setVehicleTransponder('), source.indexOf('\nDeno.serve('))
  .replace('body: Record<string, unknown>', 'body').replace('userId: string | null', 'userId')
  .replaceAll('adminClient!', 'adminClient').replace('const ids: string[]', 'const ids')
  .replace('let afterId: string | null', 'let afterId').replace('(value: unknown)', '(value)');

function fixture(rows, failRead = false) {
  const calls = [];
  const writes = [];
  const context = vm.createContext({
    normalizedTransponder: (s) => String(s || '').replace(/[^A-Za-z0-9]/g, '').toUpperCase(),
    adminClient: {
      rpc: async (name, args) => { calls.push({ name, args }); return { data: {}, error: null }; },
      from: () => {
        let after = '';
        const query = {
          select() { return this; }, in() { return this; }, not() { return this; },
          order() { return this; }, limit() { return this; }, gt(k, id) { after = id; return this; },
          insert(row) { writes.push(row); return Promise.resolve({ error: null }); },
          then(resolve) { return Promise.resolve(failRead ? { error: new Error('read failed') } : { data: rows.filter((r) => r.id > after).slice(0, 1000) }).then(resolve); },
        };
        return query;
      },
    },
  });
  vm.runInContext(handler, context);
  return { calls, writes, run: () => context.setVehicleTransponder({ vehicleId: '00000000-0000-4000-8000-000000000001', transponderNumber: 'AB-123' }, 'admin', true) };
}

test('verified transponders reprocess matches beyond the first 1000 fleet tolls in bounded batches', async () => {
  const rows = Array.from({ length: 1250 }, (_, i) => ({ id: String(i).padStart(5, '0'), transponder_number: i < 1000 ? 'OTHER' : 'AB 123' }));
  const f = fixture(rows);
  const result = await f.run();
  assert.equal(result.reprocessed, 250);
  const batches = f.calls.filter((c) => c.name === 'service_match_tollspot_transactions');
  assert.deepEqual(batches.map((c) => c.args.p_transaction_ids.length), [100, 100, 50]);
  assert.equal(new Set(batches.flatMap((c) => Array.from(c.args.p_transaction_ids))).size, 250);
  assert.equal(f.writes[0].metadata.reprocessed_transactions, 250);
});

test('a failed backlog read does not report successful reprocessing', async () => {
  const f = fixture([], true);
  await assert.rejects(f.run(), /read failed/);
  assert.equal(f.calls.some((c) => c.name === 'service_match_tollspot_transactions'), false);
  assert.equal(f.writes.length, 0);
});
