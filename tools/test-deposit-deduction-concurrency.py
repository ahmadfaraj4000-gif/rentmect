"""Disposable local PostgreSQL only; no provider calls or real customer records."""
import concurrent.futures
from pathlib import Path
import subprocess
import sys
import uuid

import os
from urllib.parse import urlparse
url = os.environ.get('RENTMECT_TEST_DATABASE_URL', '')
if not url or urlparse(url).hostname not in ('localhost', '127.0.0.1', '::1'):
    raise SystemExit('Use only the disposable localhost full-schema test database.')
base = [str(Path(os.environ.get('PG_BINDIR', '/usr/bin')) / 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', url]
actor = '11111111-1111-4111-8111-111111111111'
claims = f"set request.jwt.claim.sub='{actor}'; set request.jwt.claim.role='service_role';"

def sql(statement, required=True):
    result = subprocess.run(base, input=claims + statement, capture_output=True, text=True, timeout=30)
    if required and result.returncode:
        raise AssertionError(result.stderr)
    return result

fixture = Path('supabase/tests/fixtures/account_fixture.sql').read_text()
setup = fixture + r"""
select pg_temp.account_fixture(300,813.67) as rid \gset
insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
 values(:'rid',:'rid','local',300,'held') returning id as aid \gset
insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount)
 select id,user_id,'Synthetic concurrent fuel','fuel',50,false,50 from rentals where id=:'rid' returning id as cid \gset
select :'rid'||','||:'aid'||','||:'cid';
"""

def deduction(rid, aid, cid, key):
    return f"""select service_deduct_deposit_charges('{rid}','{aid}',array['{cid}']::uuid[],50,250,
    (select jsonb_agg(to_jsonb(c)) from rental_charge_items c where id='{cid}'),
    (select to_jsonb(a) from rental_deposit_allocations a where id='{aid}'),'{actor}','Concurrent synthetic deduction','{key}');"""

for scenario in ['different requests', 'identical retry', 'refund against deduction']:
    rid, aid, cid = sql(setup).stdout.strip().splitlines()[-1].split(',')
    first = deduction(rid, aid, cid, str(uuid.uuid4()))
    second = first if scenario == 'identical retry' else deduction(rid, aid, cid, str(uuid.uuid4()))
    if scenario == 'refund against deduction':
        # A pending unrelated add-on makes the real refund refuse the transaction;
        # after deduction, the inspected rental may release only its remainder.
        sql(f"set session_replication_role=replica; update rentals set status='completed',inspection_completed_at=now() where id='{rid}'; set session_replication_role=origin;")
        second = f"set request.jwt.claim.role='authenticated'; select admin_record_local_deposit_release('{rid}');"
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        results = list(pool.map(lambda statement: sql('begin;' + statement + 'commit;', False), [first, second]))
    successes = sum(r.returncode == 0 for r in results)
    amounts = sql(f"select amount_applied||','||amount_released||','||(amount_held-amount_applied-amount_released) from rental_deposit_allocations where id='{aid}';").stdout.strip()
    if scenario == 'identical retry':
        assert successes == 2 and amounts == '50.00,0,250.00', (scenario, amounts, [r.stderr for r in results])
    elif scenario == 'different requests':
        assert successes == 1 and amounts == '50.00,0,250.00', (scenario, amounts, [r.stderr for r in results])
    else:
        # Either the refund waits for the deduction and returns 250, or it sees
        # the still-unpaid charge and refuses. It must never return the full 300.
        numbers = [float(x) for x in amounts.split(',')]
        assert numbers[0] == 50 and numbers[1] in (0, 250) and sum(numbers) == 300, (scenario, amounts, [r.stderr for r in results])
    print('PASS', scenario, amounts)
