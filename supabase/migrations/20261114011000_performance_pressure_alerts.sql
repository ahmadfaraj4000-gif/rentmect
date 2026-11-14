-- Hourly observations replace hourly retention scans; retention runs once daily.
-- Database temp-file growth is a query-memory pressure signal, not host RAM usage.
begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create table public.admin_performance_health (
 recorded_at timestamptz primary key default now(), stats_reset timestamptz,
 temp_bytes bigint not null, spill_bytes bigint, alerts jsonb not null default '[]'::jsonb
);
alter table public.admin_performance_health enable row level security;
revoke all on public.admin_performance_health from public,anon,authenticated;
create function public.admin_performance_maintenance() returns void
language plpgsql security definer set search_path=pg_catalog,public set statement_timeout='3s' set lock_timeout='150ms' as $$
declare prior public.admin_performance_health%rowtype; current_bytes bigint; reset_at timestamptz; delta bigint; warnings jsonb; last_cleanup timestamptz;
begin
 if not pg_try_advisory_xact_lock(hashtext('admin_performance_maintenance')) then return; end if;
 select * into prior from public.admin_performance_health order by recorded_at desc limit 1;
 if prior.recorded_at > now()-interval '55 minutes' then return; end if;
 select temp_bytes,stats_reset into current_bytes,reset_at from pg_stat_database where datname=current_database();
 if prior.recorded_at is not null and reset_at is not distinct from prior.stats_reset and current_bytes>=prior.temp_bytes then delta:=current_bytes-prior.temp_bytes; end if;
 select coalesce(jsonb_agg(jsonb_build_object('kind','slow_load','action',action,'p95_ms',p95,'target_ms',target,'samples',samples)),'[]'::jsonb) into warnings
 from (
   select action,count(*) as samples,percentile_cont(0.95) within group(order by duration_ms) as p95,
     case action when 'rental_detail' then 1000 when 'payment_totals' then 2000 else 1500 end as target
   from public.admin_performance_samples
   where recorded_at>=now()-interval '1 hour' and outcome='success' and mode<>'background'
   group by action
 ) measured where samples>=20 and p95>target;
 if delta>=67108864 then warnings:=warnings||jsonb_build_array(jsonb_build_object('kind','query_memory_pressure','spill_bytes',delta)); end if;
 insert into public.admin_performance_health(stats_reset,temp_bytes,spill_bytes,alerts) values(reset_at,coalesce(current_bytes,0),delta,warnings);
 -- First run also establishes retention; otherwise one cleanup after each UTC date change.
 if prior.recorded_at is null or (prior.recorded_at at time zone 'UTC')::date<(now() at time zone 'UTC')::date then
   perform public.admin_performance_cleanup();
   delete from public.admin_performance_health where recorded_at<now()-interval '7 days';
 end if;
end $$;
revoke all on function public.admin_performance_maintenance() from public,anon,authenticated;
-- Keep the pre-existing job identity and schedule. No rental/billing job changes.
do $$ declare jid bigint; begin
 select jobid into strict jid from cron.job where jobname='admin-performance-retention' and command='select public.admin_performance_cleanup()';
 perform cron.alter_job(jid,command:='select public.admin_performance_maintenance()');
end $$;
-- Preserve the deployed report and its authorization checks, adding only health data.
do $$ declare d text; begin
 select pg_get_functiondef('public.admin_performance_report(integer,text,text,text)'::regprocedure) into d;
 if position('  return result;' in d)=0 or position('admin_performance_health' in d)>0 then raise exception 'Review deployed performance report before patching'; end if;
 d:=replace(d,'  return result;', $patch$  return result || jsonb_build_object('health',(select jsonb_build_object('recorded_at',recorded_at,'spill_bytes',spill_bytes,'alerts',alerts) from public.admin_performance_health order by recorded_at desc limit 1));$patch$);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
