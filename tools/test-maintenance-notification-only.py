from pathlib import Path
import gzip,subprocess,tempfile,socket,os
root=Path(__file__).resolve().parents[1]; bin=Path(os.environ.get('PG_BINDIR', '/opt/homebrew/opt/postgresql@17/bin'))
def run(cmd,*args,**kw): return subprocess.run([str(bin/cmd),*map(str,args)],check=True,**kw)
with tempfile.TemporaryDirectory() as t:
 with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
 run('initdb','-D',t+'/data','-A','trust','--no-locale','--encoding=UTF8',stdout=subprocess.DEVNULL)
 run('pg_ctl','-D',t+'/data','-l',t+'/log','-o',f'-k {t} -p {port} -h 127.0.0.1','start',stdout=subprocess.DEVNULL)
 a=['-X','-q','-v','ON_ERROR_STOP=1','-h',t,'-p',port,'-d','postgres']
 def sql(q):
  r=subprocess.run([str(bin/'psql'),*map(str,a)],input=q,text=True,capture_output=True)
  if r.returncode: raise RuntimeError(r.stderr)
  return r.stdout
 try:
  schema=gzip.decompress((root/'supabase/tests/fixtures/discount_full_schema.sql.gz').read_bytes()).decode()
  sql('create role anon; create role authenticated; create role service_role; create role supabase_auth_admin; create role supabase_storage_admin; create role authenticator; create role dashboard_user; create role supabase_admin; do $$begin if not exists(select 1 from pg_roles where rolname=\'postgres\') then create role postgres; end if; end $$;'+schema)
  hashes=sql("select md5(prosrc) from pg_proc where oid in ('public.evaluate_vehicle_maintenance(uuid)'::regprocedure,'public.enforce_rental_odometer_gate()'::regprocedure) order by proname;").splitlines()[2:4]
  hashes=[x.strip() for x in hashes]
  print('fixture hashes:',hashes)
  migration=(root/'supabase/migrations/20261116190000_maintenance_notification_only.sql').read_text().replace('10fa50f1513db189c2a9e97cc753f98f',hashes[1]).replace('6f236ff5c7b15ff127141a7c08636771',hashes[0])
  sql(migration)
  sql('''begin;
set local session_replication_role=replica;
insert into vehicles(id,name,status,current_mileage,maintenance_lock_active,published) values ('11111111-1111-4111-8111-111111111111','fixture','available',1000,false,false);
insert into vehicle_maintenance_schedules(id,vehicle_id,service_type,label,interval_miles,warning_miles,warning_days,last_service_mileage,next_due_mileage,active,lock_when_due,source) values ('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','oil_change','Oil change',500,50,10,500,1000,true,true,'oem_default');
set local session_replication_role=origin;
select public.evaluate_vehicle_maintenance('11111111-1111-4111-8111-111111111111');
do $$ begin
 if exists(select 1 from vehicles where id='11111111-1111-4111-8111-111111111111' and (maintenance_lock_active or status<>'available')) then raise exception 'due maintenance locked car'; end if;
 if not exists(select 1 from admin_notification_events where event_type='maintenance_due' and source_id='22222222-2222-4222-8222-222222222222') then raise exception 'due notice missing'; end if;
end $$;
select public.evaluate_vehicle_maintenance('11111111-1111-4111-8111-111111111111');
do $$ begin if (select count(*) from admin_notification_events where event_type='maintenance_due' and source_id='22222222-2222-4222-8222-222222222222')<>1 then raise exception 'duplicate notice'; end if; end $$;
create temporary table odometer_fixture(status text,starting_mileage integer,ending_mileage integer,vehicle_id uuid, id uuid, inspection_completed_at timestamptz);
create trigger odometer_check before insert or update on odometer_fixture for each row execute function public.enforce_rental_odometer_gate();
insert into odometer_fixture(status,starting_mileage,vehicle_id) values('active',1000,'11111111-1111-4111-8111-111111111111');
do $$ begin begin insert into odometer_fixture(status,vehicle_id) values('active','11111111-1111-4111-8111-111111111111'); raise exception 'missing mileage accepted'; exception when others then if sqlerrm not like 'Starting mileage is mandatory%' then raise; end if; end; end $$;
rollback;''')
  print('PASS: due alert, deduplication, no auto-lock, rental release, mileage gate')
 finally: run('pg_ctl','-D',t+'/data','-m','immediate','stop',stdout=subprocess.DEVNULL)
