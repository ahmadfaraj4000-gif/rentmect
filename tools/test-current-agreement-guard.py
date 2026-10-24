#!/usr/bin/env python3
"""Exercise the production signature guard in an isolated local Postgres cluster."""
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINDIR = Path(subprocess.check_output(['pg_config', '--bindir'], text=True).strip())
MIGRATION = ROOT / 'supabase/migrations/20261023220000_unreturned_keys_agreement.sql'
clause = (ROOT / 'rentmect-client-portal/src/rentalAgreement.js').read_text().split('UNRETURNED KEYS AND KEY FOBS\n')[1].split('\n\n')[0]
snapshot = 'AUTO-FILLED RENTAL DETAILS\nUNRETURNED KEYS AND KEY FOBS\n' + clause
version = 'rentmect-master-v2026-10-23-unreturned-keys-r1'

def run(name, *args, **kwargs):
    return subprocess.run([str(BINDIR / name), *map(str, args)], check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='rentme-agreement-') as temp:
    path = Path(temp)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    run('initdb', '-D', path / 'data', '-A', 'trust', '--no-locale', stdout=subprocess.DEVNULL)
    run('pg_ctl', '-D', path / 'data', '-l', path / 'postgres.log', '-o', f'-k {temp} -p {port} -h 127.0.0.1', 'start', stdout=subprocess.DEVNULL)
    try:
        args = ['-X', '-h', temp, '-p', port, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
        run('psql', *args, input="create table rental_signatures(id int, agreement_version text, agreement_snapshot text); insert into rental_signatures values(1,'previous','Historical signed copy');", text=True, stdout=subprocess.DEVNULL)
        run('psql', *args, '-f', MIGRATION, stdout=subprocess.DEVNULL)
        run('psql', *args, input=f"""
do $test$
begin
  assert (select agreement_snapshot='Historical signed copy' from rental_signatures where id=1), 'Historical agreements must remain intact';
  begin
    insert into rental_signatures values(2,'previous',$snapshot${snapshot}$snapshot$);
    raise exception 'Old version was accepted';
  exception when sqlstate '22023' then
    assert sqlerrm like '%Refresh this page%';
  end;
  begin
    insert into rental_signatures values(3,'{version}','Terms without the new clause');
    raise exception 'Missing clause was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    insert into rental_signatures values(4,null,null);
    raise exception 'Null agreement was accepted';
  exception when sqlstate '22023' then null;
  end;
  insert into rental_signatures values(5,'{version}',$snapshot${snapshot}$snapshot$);
  assert (select count(*)=2 from rental_signatures), 'Only the historic and current signed copies should exist';
end;
$test$;
""", text=True, stdout=subprocess.DEVNULL)
        print('PASS: current signature accepted; stale, null and missing-clause submissions rejected; historical signed copy preserved.')
    finally:
        run('pg_ctl', '-D', path / 'data', '-m', 'fast', 'stop', stdout=subprocess.DEVNULL)
