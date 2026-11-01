#!/usr/bin/env python3
"""Exercise production billing/quote/guard bodies on disposable local Postgres."""
from pathlib import Path
import socket
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
BINDIR=Path(subprocess.check_output(['pg_config','--bindir'],text=True).strip())
def run(name,*args,**kwargs):
 return subprocess.run([str(BINDIR/name),*map(str,args)],check=True,**kwargs)
with tempfile.TemporaryDirectory(prefix='rentme-dst-test-') as temp:
 p=Path(temp)
 with socket.socket() as sock:
  sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 run('initdb','-D',p/'data','-A','trust','--no-locale',stdout=subprocess.DEVNULL)
 run('pg_ctl','-D',p/'data','-l',p/'postgres.log','-o',f'-k {temp} -p {port} -h 127.0.0.1','start',stdout=subprocess.DEVNULL)
 try:
  args=['-X','-h',temp,'-p',port,'-d','postgres','-v','ON_ERROR_STOP=1']
  for f in ['supabase/tests/fixtures/daylight_saving_billing.sql','supabase/migrations/20261101190000_eastern_calendar_rental_days.sql','supabase/tests/daylight_saving_billing.sql']:
   run('psql',*args,'-f',ROOT/f,stdout=subprocess.DEVNULL)
  print('PASS: fall/spring rental days, true extra minutes, minimum booking guards, quote totals, real elapsed minutes, late days, and idempotent staging.')
 finally:
  run('pg_ctl','-D',p/'data','-m','fast','stop',stdout=subprocess.DEVNULL)
