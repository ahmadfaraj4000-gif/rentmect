-- Installed dormant. Activate only after reviewing the production cleanup.
-- Scan via runid (managed pg_cron tables cannot receive custom indexes).
begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create table public.cron_history_retention_state (
 id boolean primary key default true check(id), enabled boolean not null default false,
 running boolean not null default false, cutoff timestamptz,
 scan_after bigint not null default 0, scan_until bigint not null default 0,
 scanned bigint not null default 0, removed bigint not null default 0,
 started_at timestamptz, finished_at timestamptz
);
insert into public.cron_history_retention_state(id) values(true);
alter table public.cron_history_retention_state enable row level security;
revoke all on public.cron_history_retention_state from public,anon,authenticated;

create function public.start_cron_history_retention() returns void
language plpgsql security definer set search_path=pg_catalog,public
set lock_timeout='150ms' as $$
declare s public.cron_history_retention_state%rowtype; jid bigint;
begin
 if not pg_try_advisory_xact_lock(hashtext('rentmect_cron_history_retention')) then return; end if;
 select * into s from public.cron_history_retention_state where id for update;
 if not s.enabled or s.running then return; end if;
 update public.cron_history_retention_state set running=true,cutoff=now()-interval '14 days',
  scan_after=0,scan_until=coalesce((select max(runid) from cron.job_run_details),0),
  scanned=0,removed=0,started_at=now(),finished_at=null where id;
 select jobid into strict jid from cron.job where jobname='rentmect-cron-history-batch';
 perform cron.alter_job(jid,active:=true);
end $$;

create function public.prune_cron_history_batch() returns integer
language plpgsql security definer set search_path=pg_catalog,public
set lock_timeout='150ms' as $$
declare s public.cron_history_retention_state%rowtype; last_id bigint;
 n integer; scanned_count integer; jid bigint;
begin
 if not pg_try_advisory_xact_lock(hashtext('rentmect_cron_history_retention')) then return 0; end if;
 select * into s from public.cron_history_retention_state where id for update;
 if not s.enabled or not s.running then return 0; end if;
 -- At most 2,000 candidate rows; never scan the whole log in one batch.
 with batch as materialized (
  select runid,end_time,status from cron.job_run_details
  where runid>s.scan_after and runid<=s.scan_until order by runid limit 2000
 ), deleted as (
  delete from cron.job_run_details d using batch b where d.runid=b.runid
   and b.end_time<s.cutoff and b.status in ('succeeded','failed')
   and d.end_time<s.cutoff and d.status in ('succeeded','failed') returning d.runid
 ) select (select max(runid) from batch),(select count(*) from batch),
   (select count(*) from deleted) into last_id,scanned_count,n;
 update public.cron_history_retention_state set scan_after=coalesce(last_id,scan_until),
  scanned=scanned+scanned_count,removed=removed+n,
  running=not(scanned_count<2000 or last_id>=scan_until),
  finished_at=case when scanned_count<2000 or last_id>=scan_until then now() else null end
 where id;
 if scanned_count<2000 or last_id>=s.scan_until then
  select jobid into strict jid from cron.job where jobname='rentmect-cron-history-batch';
  perform cron.alter_job(jid,active:=false);
 end if;
 return n;
end $$;
revoke all on function public.start_cron_history_retention() from public,anon,authenticated,service_role;
revoke all on function public.prune_cron_history_batch() from public,anon,authenticated,service_role;
-- Each batch has its own transaction and a 3-second deadline. A timeout rolls
-- back both deletion and cursor, so the next run retries without skipping data.
select cron.schedule('rentmect-cron-history-batch','* * * * *',
 $$set statement_timeout='3s'; select public.prune_cron_history_batch();$$);
select cron.alter_job(jobid,active:=false) from cron.job where jobname='rentmect-cron-history-batch';
select cron.schedule('rentmect-cron-history-daily','41 8 * * *',
 $$set statement_timeout='3s'; select public.start_cron_history_retention();$$);
select cron.alter_job(jobid,active:=false) from cron.job where jobname='rentmect-cron-history-daily';
commit;
