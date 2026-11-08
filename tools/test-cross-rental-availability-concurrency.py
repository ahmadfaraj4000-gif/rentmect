"""Competing rentals must never claim the same replacement vehicle. Local DB only."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse
import os
import subprocess
import uuid

url = os.environ.get('RENTMECT_TEST_DATABASE_URL', '')
if urlparse(url).hostname not in ('localhost', '127.0.0.1', '::1'):
    raise SystemExit('Use only a disposable localhost test database.')
cmd = [str(Path(os.environ.get('PG_BINDIR', '/usr/bin')) / 'psql'), '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', url]
claims = "set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';set request.jwt.claim.role='authenticated';"
fixture = Path('supabase/tests/fixtures/account_fixture.sql').read_text()

def run(sql):
    return subprocess.run(cmd, input=claims+sql, capture_output=True, text=True, timeout=30)

def scalar(sql):
    result = run(sql)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1]

for mode in ['two swaps', 'two edits', 'swap versus edit']:
    car = scalar("insert into vehicles(name,daily_rate,security_deposit,status,is_active,published) values('Synthetic competing target',69,300,'available',true,false) returning id;")
    rental_ids = []
    requests = []
    for number in range(2):
        edit = mode == 'two edits' or (mode == 'swap versus edit' and number == 1)
        rid = scalar('begin;'+fixture+'select pg_temp.account_fixture();commit;')
        rental_ids.append(rid)
        scalar("begin;set local session_replication_role='replica';"+
            f"update rentals set status='{'documents_needed' if edit else 'active'}',starting_mileage={'null' if edit else '1000'},agreement_signed=false,pickup_date=current_date-2,return_date=current_date+3,rental_total=345,base_rental_total=345,tax_amount=21.91 where id='{rid}';"+
            f"update rental_vehicle_assignments set assigned_from=rentmect_rental_timestamp(current_date-2,'9:00 AM') at time zone 'America/New_York',assigned_until=rentmect_rental_timestamp(current_date+3,'9:00 AM') at time zone 'America/New_York' where rental_id='{rid}';commit;select 'ready';")
        if edit:
            scalar(f"select admin_preview_rental_amendment('{rid}','{car}',current_date-2,'9:00 AM',current_date+3,'9:00 AM',69,300)->>'rental_id';")
            requests.append(f"select admin_apply_rental_amendment('{rid}','{car}',current_date-2,'9:00 AM',current_date+3,'9:00 AM',69,300,'Synthetic simultaneous vehicle edit','Synthetic concurrency probe','{uuid.uuid4()}');")
        else:
            effective = "rentmect_rental_timestamp(current_date-1,'9:00 AM') at time zone 'America/New_York'"
            revision = scalar(f"select admin_preview_vehicle_swap('{rid}','{car}',{effective},'emergency','Synthetic simultaneous vehicle swap',null)->>'revision';")
            requests.append(f"select admin_apply_vehicle_swap('{rid}','{car}',{effective},'emergency','Synthetic simultaneous vehicle swap',null,'{uuid.uuid4()}','{revision}',1000,0);")
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(run, ['begin;'+query+"select pg_sleep(0.3);commit;" for query in requests]))
    assert sum(result.returncode == 0 for result in results) == 1, [(r.returncode,r.stderr) for r in results]
    failure = next(result for result in results if result.returncode)
    assert 'conflict' in failure.stderr.lower() or 'unavailable' in failure.stderr.lower(), failure.stderr
    assert scalar(f"select count(*) from rentals where vehicle_id='{car}' and status not in ('completed','cancelled');") == '1'
    count = scalar("select (select count(*) from rental_vehicle_swaps where rental_id in ('"+"','".join(rental_ids)+"'))+(select count(*) from rental_amendments where rental_id in ('"+"','".join(rental_ids)+"'));")
    assert count == '1', count
    print('PASS:',mode,'— exactly one rental claims the vehicle; losing request leaves no amendment or swap')
