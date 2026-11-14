#!/usr/bin/env python3
"""Run admin-confirmed return policy checks against the complete archived database schema.

No production connection is accepted. CI may supply a disposable localhost
PostgreSQL 17 service via RENTMECT_TEST_DATABASE_URL; otherwise start a temp DB.
"""
from pathlib import Path
from urllib.parse import urlparse
import gzip
import getpass
import sys
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
        run('psql', *args, input="insert into storage.buckets(id,name,public) values('ticket-evidence','ticket-evidence',false) on conflict do nothing; insert into employee_permissions(permission_key,label,category,description,enabled) values ('tab.tickets','View tickets','Visible tabs','Synthetic fixture',false),('ticket.manage','Manage tickets','Rentals','Synthetic fixture',false) on conflict(permission_key) do update set enabled=false;", text=True, stdout=subprocess.DEVNULL)
        for file in ['supabase/migrations/20261107230000_discount_history_rounding.sql',
            'supabase/migrations/20261108010000_vehicle_mileage_and_calendar_proration.sql',
            'supabase/migrations/20261108020000_atomic_return_followup.sql',
            'supabase/migrations/20261108190000_completed_rentals_do_not_block_amendments.sql',
            'supabase/migrations/20261108200000_unify_amendment_and_assignment_availability.sql',
            'supabase/migrations/20261108201000_retire_unapproved_closed_extensions.sql',
            'supabase/migrations/20261108202000_consistent_swap_vehicle_lock_order.sql',
            'supabase/migrations/20261111190000_flexible_payment_allocations.sql',
            'supabase/migrations/20261111200000_flexible_payment_consumers.sql',
            'supabase/migrations/20261111210000_flexible_stripe_charge_remainders.sql',
            'supabase/migrations/20261111220000_clear_retired_collection_attempts.sql',
            'supabase/migrations/20261111230000_allocated_stripe_collection.sql',
            'supabase/migrations/20261112010000_payment_amount_corrections.sql',
            'supabase/migrations/20261112020000_legacy_grouped_payment_corrections.sql',
            'supabase/migrations/20261112030000_stamp_verified_stripe_receipts.sql',
            'supabase/migrations/20261112040000_explicit_deposit_payment_allocations.sql',
            'supabase/migrations/20261112050000_deposit_review_workspace.sql',
            'supabase/migrations/20261112060000_payment_due_parts_permissions.sql',
            'supabase/migrations/20261112070000_deposit_first_payment_priority.sql',
            'supabase/migrations/20261112080000_dated_rental_rate_changes.sql',
            'supabase/migrations/20261114010000_rental_summary_speed.sql',
            'supabase/migrations/20261114020000_rental_card_workflow_summary.sql',
            'supabase/migrations/20261114030000_admin_return_availability.sql',
            'supabase/tests/admin_return_availability.sql',
            'supabase/tests/admin_return_balance_retirement.sql',
            'supabase/migrations/20261114032000_admin_return_agreement_version.sql',
            'supabase/migrations/20261114040000_manual_late_agreement_compatibility.sql',
            'supabase/migrations/20261114041000_manual_late_agreement_current.sql',
            'supabase/tests/load_reduction.sql',
            'supabase/tests/screen_reads.sql',
            'supabase/migrations/20261114080000_nonblank_admin_reasons.sql',
            'supabase/tests/nonblank_admin_reasons.sql',
            'supabase/migrations/20261114090000_rental_filter_consistency.sql',
            'supabase/tests/rental_filter_consistency.sql',
            'supabase/tests/payment_amount_corrections.sql',
            'supabase/tests/deposit_review_workspace.sql',
            'supabase/tests/dated_rental_rate_changes.sql',
            'supabase/tests/deposit_first_priority.sql',
            'supabase/tests/payment_due_parts_permissions.sql',
            'supabase/tests/unified_external_payments_full_schema.sql',
            'supabase/tests/flexible_payments_full_schema.sql',
            'supabase/tests/explicit_deposit_payments.sql',
            'supabase/tests/ticket_resolution.sql',
            'supabase/tests/ticket_quick_lookup_flags.sql',
            'supabase/tests/admin_return_availability.sql']:
            if file.endswith('20261114030000_admin_return_availability.sql') and os.environ.get('RENTMECT_LIVE_FUNCTION_CSV'):
                import csv
                csv.field_size_limit(10000000)
                with open(os.environ['RENTMECT_LIVE_FUNCTION_CSV']) as source:
                    live = list(csv.DictReader(source))
                # Reproduce exactly the exported production function baseline in
                # this disposable database before applying the candidate policy.
                run('psql', *args, input='\n'.join(row['definition'] + ';' for row in live),
                    text=True, stdout=subprocess.DEVNULL)
                print('PASS: restored exported production function baseline')
            if file.endswith('20261114080000_nonblank_admin_reasons.sql') and os.environ.get('RENTMECT_REASON_BASELINE'):
                sql = r"select p.proname,md5(p.prosrc) as source_hash from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f' and exists(select 1 from regexp_split_to_table(p.prosrc,E'\\n') l where l ~* '(reason|note)' and l ~* 'length\(' and l ~ '(<|>=)[[:space:]]*(3|5|8|10|20)\M') order by p.proname"
                with open(os.environ['RENTMECT_REASON_BASELINE'],'w') as baseline:
                    run('psql',*args,'--csv','-c',sql,stdout=baseline)
            result = subprocess.run([str(BIN / 'psql'), *map(str, args), '-f', str(ROOT / file)],
                text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(file + '\n' + result.stdout + '\n' + result.stderr)
            print('PASS:', file)
        test_url = url or f'postgresql://{getpass.getuser()}@127.0.0.1:{port}/postgres'
        subprocess.run([sys.executable, str(ROOT / 'tools/test-cross-rental-availability-concurrency.py')],
            cwd=ROOT, env={**os.environ, 'PG_BINDIR': str(BIN), 'RENTMECT_TEST_DATABASE_URL': test_url}, check=True)
    finally:
        if started:
            run('pg_ctl', '-D', path / 'data', '-m', 'fast', 'stop', stdout=subprocess.DEVNULL)
