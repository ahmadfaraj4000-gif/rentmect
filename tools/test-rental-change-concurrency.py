"""Synthetic committed concurrency probes in the disposable full-schema runner."""
import concurrent.futures
import pathlib
import subprocess
import sys
import uuid

import os
from urllib.parse import urlparse
url = os.environ.get('RENTMECT_TEST_DATABASE_URL', '')
if not url or urlparse(url).hostname not in ('localhost', '127.0.0.1', '::1'):
    raise SystemExit('Use only the disposable localhost full-schema test database.')
command = [str(pathlib.Path(os.environ.get('PG_BINDIR', '/usr/bin')) / 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', url]
claims = "set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111'; set request.jwt.claim.role='authenticated';"
fixture = pathlib.Path('supabase/tests/fixtures/account_fixture.sql').read_text()


def run(sql):
    return subprocess.run(command, input=sql, capture_output=True, text=True, timeout=30)


def scalar(sql):
    result = run(sql)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1]


for scenario in ['different extensions', 'identical retry', 'swap versus extension']:
    rental = scalar(claims + 'begin;' + fixture + 'select pg_temp.account_fixture(300,813.67); commit;')
    revision = scalar(claims + f"select public.admin_preview_rental_extension('{rental}',current_date+7,'9:00 AM',69,'Concurrency probe')->>'revision';")
    key = str(uuid.uuid4())

    def extension(request_key):
        return f"select public.admin_apply_rental_extension('{rental}',current_date+7,'9:00 AM',69,'Concurrency probe','{request_key}','{revision}');"

    first = extension(key)
    second = extension(key if scenario == 'identical retry' else str(uuid.uuid4()))
    if scenario == 'swap versus extension':
        car = scalar("insert into public.vehicles(name,daily_rate,security_deposit,status,is_active,published) values('Synthetic concurrency replacement',69,300,'available',true,false) returning id;")
        effective = "public.rentmect_rental_timestamp(current_date-1,'9:00 AM') at time zone 'America/New_York'"
        swap_revision = scalar(claims + f"select public.admin_preview_vehicle_swap('{rental}','{car}',{effective},'emergency','Concurrency probe',null)->>'revision';")
        second = f"select public.admin_apply_vehicle_swap('{rental}','{car}',{effective},'emergency','Concurrency probe',null,'{uuid.uuid4()}','{swap_revision}',1000,0);"
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run, claims + 'begin;' + sql + 'select pg_sleep(0.5); commit;') for sql in [first, second]]
        results = [future.result() for future in futures]
    passed = [result for result in results if result.returncode == 0]
    assert len(passed) == (2 if scenario == 'identical retry' else 1), [(r.returncode, r.stderr) for r in results]
    for result in results:
        if result.returncode:
            assert 'Review the ' in result.stderr or 'New return must be after the booked return' in result.stderr, result.stderr
    count = scalar(f"select (select count(*) from rental_admin_extensions where rental_id='{rental}') + (select count(*) from rental_vehicle_swaps where rental_id='{rental}');")
    assert count == '1', count
    scalar(f"select public.rentmect_assert_period_financial_totals('{rental}'); select 'consistent';")
    print(scenario + ': passed; exactly one committed change')

# Use separate committed transactions: an audited mileage override must not
# prevent subsequent payment/deposit metadata updates on the closed rental.
rental = scalar(claims + 'begin;' + fixture + 'select pg_temp.account_fixture(300,813.67); commit;')
scalar(claims + f"select public.admin_inspect_and_complete_rental_return('{rental}',null,false,true,true,false,'release','Odometer display is unreadable','available',true); select 'closed';")
scalar(claims + f"update rentals set updated_at=clock_timestamp() where id='{rental}'; select 'updated';")
assert scalar(f"select status||','||(ending_mileage is null)::text from rentals where id='{rental}';") == 'completed,true'
print('PASS: audited override permits later updates in a separate transaction')
