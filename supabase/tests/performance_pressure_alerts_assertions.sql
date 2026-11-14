-- Run inside a rollback transaction after applying the candidate.
insert into public.admin_performance_health(recorded_at,stats_reset,temp_bytes)
 select now()-interval '1 hour',stats_reset,temp_bytes-73400320 from pg_stat_database where datname=current_database();
insert into public.admin_performance_samples(id,action,mode,cache,outcome,duration_ms,device,release)
 select gen_random_uuid(),'rental_archive','initial','network','success',100000,'desktop','0000000' from generate_series(1,600);
select public.admin_performance_maintenance();
select public.admin_performance_maintenance();
do $$ declare h public.admin_performance_health%rowtype; begin
 select * into h from public.admin_performance_health order by recorded_at desc limit 1;
 if (select count(*) from public.admin_performance_health)<>2 then raise exception 'Repeated monitor did not deduplicate'; end if;
 if not exists(select 1 from jsonb_array_elements(h.alerts) a where a->>'kind'='query_memory_pressure') then raise exception 'Missing spill alert'; end if;
 if not exists(select 1 from jsonb_array_elements(h.alerts) a where a->>'kind'='slow_load' and a->>'action'='rental_archive') then raise exception 'Missing slow-load alert'; end if;
 if has_table_privilege('authenticated','public.admin_performance_health','SELECT') then raise exception 'Direct health table access allowed'; end if;
 if has_function_privilege('authenticated','public.admin_performance_maintenance()','EXECUTE') then raise exception 'Staff monitor execution allowed'; end if;
 perform set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='admin' limit 1),true);
 if public.admin_performance_report()->'health'->'alerts' is distinct from h.alerts then raise exception 'Report did not expose alerts'; end if;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.admin_performance_report(); raise exception 'Anonymous report allowed'; exception when insufficient_privilege then null; end;
end $$;
