#!/usr/bin/env python3
"""Test discount allocation through actual captured RPCs/trigger on isolated PostgreSQL."""
from pathlib import Path
import subprocess,tempfile,socket
ROOT=Path(__file__).resolve().parents[1]
BIN=Path(subprocess.check_output(['pg_config','--bindir'],text=True).strip())
def run(name,*args,**kwargs):return subprocess.run([str(BIN/name),*map(str,args)],check=True,**kwargs)
with tempfile.TemporaryDirectory(prefix='rentme-discount-test-') as tmp:
 p=Path(tmp)
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 run('initdb','-D',p/'data','-A','trust','--no-locale',stdout=subprocess.DEVNULL)
 run('pg_ctl','-D',p/'data','-l',p/'postgres.log','-o',f'-k {tmp} -p {port} -h 127.0.0.1','start',stdout=subprocess.DEVNULL)
 try:
  args=['-X','-h',tmp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1']
  for file in ['supabase/tests/fixtures/discount_period_allocation.sql','supabase/migrations/20261105180000_preserve_discount_period_allocations.sql','supabase/tests/discount_period_allocation.sql']:
   run('psql',*args,'-f',ROOT/file,stdout=subprocess.DEVNULL)
  print('PASS: original-discount removal after extension, exact period restoration, replaced discounts, real-receipt classification/credit, idempotency, split periods, missing-date rejection, fully comped periods.')
 finally:run('pg_ctl','-D',p/'data','-m','fast','stop',stdout=subprocess.DEVNULL)
