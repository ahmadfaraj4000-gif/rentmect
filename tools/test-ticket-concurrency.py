"""Synthetic concurrency checks; only an isolated ticket_resolution_* local DB is allowed."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import uuid

database = sys.argv[1]
assert database.startswith('ticket_resolution_')
command = ['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', '/tmp', '-p', '55439', '-d', database]
claims = "set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111'; set request.jwt.claim.role='authenticated';"

def run(sql):
    return subprocess.run(command, input=claims + sql, capture_output=True, text=True, timeout=15)

def scalar(sql):
    result = run(sql)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1]

def literal(value):
    return "'" + str(value).replace("'", "''") + "'"

fixture = Path('supabase/tests/fixtures/ticket_account_fixture.sql').read_text()
rental = scalar('begin;' + fixture + 'select pg_temp.ticket_account_fixture();commit;')
car = scalar(f"select vehicle_id from rentals where id='{rental}';")
data = dict(agency='Synthetic concurrency', ticket_number=str(uuid.uuid4()), vehicle_id=car, violation_date='2026-10-03', violation_time='19:55:19', timezone='America/New_York')
payload = literal(json.dumps(data))
ids = [str(uuid.uuid4()), str(uuid.uuid4())]

def run_concurrently(sqls):
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(run, ['begin;' + sql + ';select pg_sleep(0.15);commit;' for sql in sqls]))

results = run_concurrently([f"select admin_ticket_save('{tid}',null,{payload})" for tid in ids])
assert all(result.returncode == 0 for result in results), [r.stderr for r in results]
assert scalar(f"select count(*) from ticket_cases where ticket_number={literal(data['ticket_number'])}") == '1'
ticket = scalar(f"select id from ticket_cases where ticket_number={literal(data['ticket_number'])}")
results = run_concurrently([f"select admin_ticket_save('{ticket}',1,{literal(json.dumps(dict(data, notes=note)))})" for note in ['first edit', 'second edit']])
assert sum(result.returncode == 0 for result in results) == 1, [r.stderr for r in results]
assert any('This ticket changed' in result.stderr for result in results)
assert scalar(f"select version from ticket_cases where id='{ticket}'") == '2'
print('PASS simultaneous duplicate creation stores one case; competing edits preserve one revision and reject the stale writer')
