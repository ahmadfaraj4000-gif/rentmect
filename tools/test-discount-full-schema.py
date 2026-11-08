#!/usr/bin/env python3
"""Run discount lifecycle checks against the complete pre-repair database schema.

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
        migrations = [
            'supabase/migrations/20261107230000_discount_history_rounding.sql',
            'supabase/migrations/20261108010000_vehicle_mileage_and_calendar_proration.sql',
            'supabase/migrations/20261108020000_atomic_return_followup.sql',
            'supabase/migrations/20261108190000_completed_rentals_do_not_block_amendments.sql',
            'supabase/migrations/20261108200000_unify_amendment_and_assignment_availability.sql',
            'supabase/migrations/20261108201000_retire_unapproved_closed_extensions.sql',
            'supabase/migrations/20261108202000_consistent_swap_vehicle_lock_order.sql',
        ]
        for file in migrations:
            run('psql', *args, '-f', ROOT / file, stdout=subprocess.DEVNULL)
        # Configuration rows are part of the disposable fixture, never copied from customers.
        run('psql', *args, input="""begin; set local session_replication_role='replica';
          insert into auth.users(id) values('11111111-1111-4111-8111-111111111111');
          insert into profiles(id,role,staff_role,date_of_birth) values('11111111-1111-4111-8111-111111111111','admin','owner','1980-01-01');
          insert into billing_automation_settings(id) values(true);
          insert into under_25_pricing_settings(id) values(true);
          insert into vehicles(id,name,daily_rate,security_deposit,status,published) values('00000000-0000-4000-8000-000000000015','Synthetic preview',59,350,'available',false);
          insert into storage.buckets(id,name,public) values('ticket-evidence','ticket-evidence',false);
          insert into employee_permissions(permission_key,label,category,description,enabled) values
           ('tab.tickets','View tickets','Visible tabs','Synthetic fixture',false),('ticket.manage','Manage tickets','Rentals','Synthetic fixture',false);
          commit;""", text=True, stdout=subprocess.DEVNULL)
        tests = ['discount_history_rounding','extension_discount_safety','rental_account_consistency',
          'customer_availability','unified_external_payments_full_schema','admin_direct_rental_extensions',
          'dated_vehicle_swaps_and_pricing','discounts_and_legacy_assignments','client_extension_and_deposit_changes',
          'deposit_rental_balance_closeout','linked_continuation_accounting','vehicle_conflict_checks',
          'thirty_day_deposit_return','vehicle_deposit_source_of_truth','customer_identity_blocks',
          'ticket_resolution','ticket_quick_lookup_flags','vehicle_mileage_returns','calendar_swap_proration','atomic_return_followup','completed_rental_amendment_conflicts','rental_availability_stale_history','closed_rental_extension_cleanup']
        for file in ['supabase/tests/'+name+'.sql' for name in tests]:
            result = subprocess.run([str(BIN / 'psql'), *map(str, args), '-f', str(ROOT / file)],
                text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(file + '\n' + result.stdout + '\n' + result.stderr)
            print('PASS:', file)
        concurrency_env = {**os.environ, 'PG_BINDIR': str(BIN),
            'RENTMECT_TEST_DATABASE_URL': url or f'postgresql://{os.environ.get("USER", "postgres")}@127.0.0.1:{port}/postgres'}
        for script in ['test-rental-change-concurrency.py','test-deposit-deduction-concurrency.py','test-cross-rental-availability-concurrency.py']:
            subprocess.run(['python3', str(ROOT / 'tools' / script)], cwd=ROOT,
                env=concurrency_env, check=True)

    finally:
        if started:
            run('pg_ctl', '-D', path / 'data', '-m', 'fast', 'stop', stdout=subprocess.DEVNULL)
