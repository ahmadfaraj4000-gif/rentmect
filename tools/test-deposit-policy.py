#!/usr/bin/env python3
"""Test the real deposit migration/trigger functions in a disposable PostgreSQL cluster.
Requires initdb, pg_ctl and psql on PATH (or PostgreSQL binaries via pg_config).
Never connects to the linked Supabase project or Stripe.
"""
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINDIR = Path(subprocess.check_output(["pg_config", "--bindir"], text=True).strip())
def run(name, *args, **kwargs):
    return subprocess.run([str(BINDIR / name), *map(str, args)], check=True, **kwargs)

FIXTURE = "create role anon; create role authenticated; create role service_role;\ncreate table billing_automation_settings(id boolean primary key default true, automatic_deposit_release_enabled boolean default true, deposit_release_delay_days integer default 7);\ninsert into billing_automation_settings values(true,true,7);\ncreate table rentals(id uuid primary key, status text, payment_provider text, deposit_status text, return_initiated_at timestamptz, inspection_completed_at timestamptz, deposit_release_due_at timestamptz, deposit_release_reason text, deposit_release_error text);\ncreate table rental_return_inspections(rental_id uuid, created_at timestamptz, deposit_decision text);\ncreate function schedule_rentmect_deposit_release() returns trigger language plpgsql as $$ begin return new; end $$;\ncreate trigger rentals_schedule_deposit_release before update on rentals for each row execute function schedule_rentmect_deposit_release();\ncreate function apply_billing_automation_to_held_deposits() returns trigger language plpgsql as $$ begin return new; end $$;\ncreate trigger billing_automation_reschedule_deposits after update of automatic_deposit_release_enabled,deposit_release_delay_days on billing_automation_settings for each row execute function apply_billing_automation_to_held_deposits();\ninsert into rentals values('00000000-0000-0000-0000-000000000001','completed','stripe','held','2026-10-22 14:00-04','2026-10-23 14:00-04','2026-10-29 14:00-04',null,null);\n"
RESCHEDULE_TEST = "begin;\ndo $$\nbegin\n assert (select deposit_release_due_at='2026-11-21 14:00-05'::timestamptz from rentals where id='00000000-0000-0000-0000-000000000001'), 'Migration reschedules existing queue from return, not now';\n update billing_automation_settings set deposit_release_delay_days=30 where id=true;\n assert (select deposit_release_due_at='2026-11-21 14:00-05'::timestamptz from rentals where id='00000000-0000-0000-0000-000000000001'), 'Saving settings must not restart the clock';\n update rentals set deposit_release_error='Review required',deposit_release_due_at=null;\n update billing_automation_settings set deposit_release_delay_days=30;\n assert (select deposit_release_due_at is null from rentals limit 1), 'Failed refund must not be retried through settings';\n update rentals set deposit_release_error=null;\n insert into rental_return_inspections values('00000000-0000-0000-0000-000000000001',now(),'hold');\n update billing_automation_settings set deposit_release_delay_days=30;\n assert (select deposit_release_due_at is null from rentals limit 1), 'Inspection hold must remain';\n delete from rental_return_inspections;\n update rentals set return_initiated_at=null,inspection_completed_at=null,deposit_release_due_at=now();\n update billing_automation_settings set deposit_release_delay_days=30;\n assert (select deposit_release_due_at is null from rentals limit 1), 'Missing return evidence must never retain an old seven-day deadline';\n update rentals set return_initiated_at='2026-10-22 14:00-04';\n update billing_automation_settings set automatic_deposit_release_enabled=false;\n assert (select deposit_release_due_at is null from rentals limit 1);\n update billing_automation_settings set automatic_deposit_release_enabled=true;\n assert (select deposit_release_due_at='2026-11-21 14:00-05'::timestamptz from rentals limit 1), 'Re-enabling must retain return-based deadline';\nend $$;\nrollback;\n"
with tempfile.TemporaryDirectory(prefix="rentme-deposit-") as temp:
    path = Path(temp)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    run("initdb", "-D", path / "data", "-A", "trust", "--no-locale", stdout=subprocess.DEVNULL)
    run("pg_ctl", "-D", path / "data", "-l", path / "postgres.log", "-o", f"-k {temp} -p {port} -h 127.0.0.1", "start", stdout=subprocess.DEVNULL)
    try:
        args = ["-X", "-h", temp, "-p", port, "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
        run("psql", *args, input=FIXTURE, text=True, stdout=subprocess.DEVNULL)
        run("psql", *args, "-f", ROOT / "supabase/migrations/20261022210000_thirty_day_deposit_return.sql", stdout=subprocess.DEVNULL)
        run("psql", *args, "-f", ROOT / "supabase/tests/thirty_day_deposit_return.sql", stdout=subprocess.DEVNULL)
        run("psql", *args, input=RESCHEDULE_TEST, text=True, stdout=subprocess.DEVNULL)
        print("PASS: 30-day default, existing queue, Eastern DST, early refund, external deposits, settings resave, failed refunds and inspection holds.")
    finally:
        run("pg_ctl", "-D", path / "data", "-m", "fast", "stop", stdout=subprocess.DEVNULL)
