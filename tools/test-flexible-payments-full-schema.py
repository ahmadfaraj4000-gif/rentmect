#!/usr/bin/env python3
"""Run flexible payment checks against the complete archived database schema.

No production connection is accepted. CI may supply a disposable localhost
PostgreSQL 17 service via RENTMECT_TEST_DATABASE_URL; otherwise start a temp DB.
"""
from pathlib import Path
from urllib.parse import urlparse
import gzip
import os
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
url = os.environ.get('RENTMECT_TEST_DATABASE_URL')
if url and urlparse(url).hostname not in ('localhost', '127.0.0.1', '::1'):
    raise SystemExit('Only a disposable localhost database is allowed.')
default_bin = '/opt/homebrew/opt/postgresql@17/bin'
BIN = Path(os.environ.get('PG_BINDIR') or (default_bin if Path(default_bin).exists()
    else subprocess.check_output(['pg_config', '--bindir'], text=True).strip()))

def run(name, *args, **kwargs):
    return subprocess.run([str(BIN / name), *map(str, args)], check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='rentme-discount-schema-') as temp:
    path = Path(temp)
    started = False
    if url:
        args = ['-X', '-q', '-v', 'ON_ERROR_STOP=1', url]
    else:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run('initdb', '-D', path / 'data', '-A', 'trust', '--no-locale', '--encoding=UTF8', stdout=subprocess.DEVNULL)
        run('pg_ctl', '-D', path / 'data', '-l', path / 'postgres.log', '-o',
            f'-k {temp} -p {port} -h 127.0.0.1', 'start', stdout=subprocess.DEVNULL)
        started = True
        args = ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', temp, '-p', port, '-d', 'postgres']
    try:
        schema = gzip.decompress((ROOT / 'supabase/tests/fixtures/discount_full_schema.sql.gz').read_bytes()).decode()
        run('psql', *args, input="create role anon; create role authenticated; create role service_role; create role supabase_auth_admin; create role supabase_storage_admin; create role authenticator; create role dashboard_user; create role supabase_admin; do $$begin if not exists(select 1 from pg_roles where rolname='postgres') then create role postgres; end if; end $$;" + schema,
            text=True, stdout=subprocess.DEVNULL)
        for file in [
            'supabase/migrations/20261111190000_flexible_payment_allocations.sql',
            'supabase/migrations/20261111200000_flexible_payment_consumers.sql',
            'supabase/migrations/20261111210000_flexible_stripe_charge_remainders.sql',
            'supabase/migrations/20261111220000_clear_retired_collection_attempts.sql',
            'supabase/tests/unified_external_payments_full_schema.sql',
            'supabase/tests/flexible_payments_full_schema.sql',
        ]:
            result = subprocess.run([str(BIN / 'psql'), *map(str, args), '-f', str(ROOT / file)],
                text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(file + '\n' + result.stdout + '\n' + result.stderr)
            print('PASS:', file)
    finally:
        if started:
            run('pg_ctl', '-D', path / 'data', '-m', 'fast', 'stop', stdout=subprocess.DEVNULL)
