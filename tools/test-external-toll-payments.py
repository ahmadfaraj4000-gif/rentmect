#!/usr/bin/env python3
"""Exercise atomic toll receipts and real concurrency on disposable PostgreSQL."""
from pathlib import Path
import socket,subprocess,tempfile,time,json
ROOT=Path(__file__).resolve().parents[1]
BIN=Path(subprocess.check_output(['pg_config','--bindir'],text=True).strip())
def run(name,*args,**kwargs):
    return subprocess.run([str(BIN/name),*map(str,args)],check=True,**kwargs)
with tempfile.TemporaryDirectory(prefix='rentme-toll-test-') as tmp:
    path=Path(tmp)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    run('initdb','-D',path/'data','-A','trust','--no-locale',stdout=subprocess.DEVNULL)
    run('pg_ctl','-D',path/'data','-l',path/'postgres.log','-o',f'-k {tmp} -p {port} -h 127.0.0.1','start',stdout=subprocess.DEVNULL)
    try:
        args=['-X','-h',tmp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1']
        for file in ['supabase/tests/fixtures/external_toll_payments.sql','supabase/migrations/20261105160000_external_toll_payment_batches.sql','supabase/tests/external_toll_payments.sql']:
            run('psql',*args,'-f',ROOT/file,stdout=subprocess.DEVNULL)
        req=json.dumps({'charges':[{'id':'30000000-0000-4000-8000-000000000004','amountCents':400}], 'amountCents':400,'paymentMethod':'cash','receivedDate':'2026-01-01','reference':'concurrent'})
        prepare=f"select set_config('request.jwt.claim.role','service_role',false);select test_toll_prepare('{req}','40000000-0000-4000-8000-000000000004');"
        first=subprocess.Popen([str(BIN/'psql'),*map(str,args),'-c','begin;'+prepare+'select pg_advisory_xact_lock(6511005);select pg_sleep(1.2);commit;'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            for _ in range(100):
                ready=run('psql',*args,'-Atc',"select count(*) from pg_locks where locktype='advisory' and objid=6511005 and granted",capture_output=True,text=True)
                if int(ready.stdout.strip()):break
                time.sleep(.01)
            else:raise AssertionError('Reservation did not acquire its locks')
            second=subprocess.run([str(BIN/'psql'),*map(str,args),'-c',"update rental_charge_items set status='paid',payment_provider='deposit' where name='Toll 4'"],capture_output=True,text=True)
            _,err=first.communicate(timeout=10)
            assert first.returncode==0,err
            assert second.returncode!=0 and 'external payment receipt' in second.stderr,second.stderr
            run('psql',*args,'-c',prepare,stdout=subprocess.DEVNULL)
            finish="select set_config('request.jwt.claim.role','service_role',false); select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001');"
            procs=[subprocess.Popen([str(BIN/'psql'),*map(str,args),'-c',finish],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for _ in range(2)]
            for proc in procs:
                _,err=proc.communicate(timeout=10);assert proc.returncode==0,err
            run('psql',*args,'-c',"do $$ begin assert (select count(*)=1 from rental_audit_events where event_payload->>'receipt_id'='40000000-0000-4000-8000-000000000004'); assert (select sum(payment_amount_cents)=700 from rental_charge_items where status='paid');end $$;",stdout=subprocess.DEVNULL)
        finally:
            if first.poll() is None:first.kill();first.wait()
        print('PASS: authorization, exact allocations, stale/cross-rental charges, rollback, TollSpot propagation, immutable paid receipts, cancellation, retries and concurrent collections.')
    finally:
        run('pg_ctl','-D',path/'data','-m','fast','stop',stdout=subprocess.DEVNULL)
