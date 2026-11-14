\set ON_ERROR_STOP on
-- Disposable test database only: simulate the managed scheduler interface.
create schema cron;
create table cron.job(jobid bigserial primary key,jobname text unique,schedule text,command text,active boolean default true);
create table cron.job_run_details(runid bigint primary key,end_time timestamptz,status text);
create function cron.schedule(text,text,text) returns bigint language sql as $$
 insert into cron.job(jobname,schedule,command) values($1,$2,$3) returning jobid $$;
create function cron.alter_job(job_id bigint,active boolean) returns void language sql as $$
 update cron.job set active=$2 where jobid=$1 $$;
\ir ../migrations/20261114060000_bounded_cron_history_retention.sql
\ir ../migrations/20261114061000_avoid_unchanged_rental_balance_writes.sql
\ir ../migrations/20261114062000_admin_audit_history_pages.sql
begin;
do $$ declare removed integer; begin
 insert into cron.job_run_details select n,now()-interval '20 days','succeeded' from generate_series(1,4100) n;
 insert into cron.job_run_details values(4101,now()-interval '15 days','failed'),
 (4102,now()-interval '13 days','succeeded'),(4103,null,'running'),(4104,now()-interval '20 days','running');
 assert (select bool_and(not active) from cron.job),'Retention must install dormant';
 perform start_cron_history_retention();
 assert not (select running from cron_history_retention_state),'Disabled retention cannot start';
 update cron_history_retention_state set enabled=true;
 perform start_cron_history_retention();
 removed:=prune_cron_history_batch(); assert removed=2000;
 assert (select count(*)=2104 from cron.job_run_details),'Batch must be bounded';
 assert prune_cron_history_batch()=2000;
 assert prune_cron_history_batch()=101;
 assert (select count(*)=3 from cron.job_run_details),'Recent and nonterminal runs survive';
 assert not (select running from cron_history_retention_state);
 assert not (select active from cron.job where jobname='rentmect-cron-history-batch');
 assert prune_cron_history_batch()=0;
 assert (select r.removed=4101 and r.scanned=4104 from cron_history_retention_state r);
end $$;
rollback;
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; before_tid tid; after_tid tid; before_steps jsonb; after_steps jsonb; before_charges jsonb; after_charges jsonb; result jsonb; amount numeric; begin
 foreach amount in array array[0::numeric,100::numeric,813.67::numeric] loop
  rid:=pg_temp.account_fixture(300,amount);
  perform sync_rental_remaining_balance(rid,auth.uid());
  -- Allow derived deposit allocation to settle, then require idempotent writes.
  perform sync_rental_remaining_balance(rid,auth.uid());
  select ctid into before_tid from rentals where id=rid;
  select jsonb_agg(jsonb_build_object('id',id,'ctid',ctid::text) order by id) into before_steps from rental_step_completions where rental_id=rid;
  select jsonb_agg(jsonb_build_object('id',id,'ctid',ctid::text) order by id) into before_charges from rental_charge_items where rental_id=rid;
  result:=sync_rental_remaining_balance(rid,auth.uid());
  select jsonb_agg(jsonb_build_object('id',id,'ctid',ctid::text) order by id) into after_charges from rental_charge_items where rental_id=rid;
  assert before_charges is not distinct from after_charges,'Repeated reconciliation rewrote charges';
  select ctid into after_tid from rentals where id=rid;
  select jsonb_agg(jsonb_build_object('id',id,'ctid',ctid::text) order by id) into after_steps from rental_step_completions where rental_id=rid;
  assert before_tid=after_tid,'Repeated reconciliation rewrote rental';
  assert before_steps is not distinct from after_steps,'Repeated reconciliation rewrote steps';
  assert (result->>'net_paid')::numeric=amount;
  assert (result->>'balance_due')::numeric=greatest(813.67-amount,0);
 end loop;
end $$;
do $$ declare data jsonb; begin
 insert into admin_audit_logs(action,entity_type,metadata)
 select 'load_reduction_test','test_record',jsonb_build_object('large_detail',repeat('x',2000)) from generate_series(1,61);
 data:=admin_audit_history_page('','','','load_reduction_test',0);
 assert jsonb_array_length(data->'rows')=50 and (data->>'has_more')::boolean;
 assert not (data->'rows'->0 ? 'metadata'),'Collapsed audit rows leaked detail';
 assert length(admin_audit_history_detail((data->'rows'->0->>'id')::uuid)->'metadata'->>'large_detail')=2000;
 data:=admin_audit_history_page('','','','load_reduction_test',50);
 assert jsonb_array_length(data->'rows')=11 and not (data->>'has_more')::boolean;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform admin_audit_history_page();raise exception 'Unauthorized audit access accepted';
 exception when others then assert sqlerrm='Audit access is required.',sqlerrm;end;
end $$;
rollback;
