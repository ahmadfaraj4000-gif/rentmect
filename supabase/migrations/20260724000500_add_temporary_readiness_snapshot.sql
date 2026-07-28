-- Temporary service-role-only production readiness probe.
-- Removed by the next migration after its result is collected.

create or replace function public.rentmect_temporary_readiness_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cron_jobs jsonb := '[]'::jsonb;
  v_vault_secret_names jsonb := '[]'::jsonb;
  v_rls_disabled jsonb := '[]'::jsonb;
  v_anon_privileges jsonb := '[]'::jsonb;
begin
  if to_regclass('cron.job') is not null then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'jobname', jobs.jobname,
          'schedule', jobs.schedule,
          'active', jobs.active
        )
        order by jobs.jobname
      ),
      '[]'::jsonb
    )
    into v_cron_jobs
    from cron.job as jobs;
  end if;

  if to_regclass('vault.secrets') is not null then
    select coalesce(jsonb_agg(secrets.name order by secrets.name), '[]'::jsonb)
    into v_vault_secret_names
    from vault.secrets as secrets;
  end if;

  select coalesce(jsonb_agg(tables.tablename order by tables.tablename), '[]'::jsonb)
  into v_rls_disabled
  from pg_catalog.pg_tables as tables
  where tables.schemaname = 'public'
    and not tables.rowsecurity;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'table', grants.table_name,
        'privilege', grants.privilege_type
      )
      order by grants.table_name, grants.privilege_type
    ),
    '[]'::jsonb
  )
  into v_anon_privileges
  from information_schema.role_table_grants as grants
  where grants.table_schema = 'public'
    and grants.grantee in ('anon', 'PUBLIC')
    and grants.table_name <> 'vehicles';

  return jsonb_build_object(
    'cron_jobs', v_cron_jobs,
    'vault_secret_names', v_vault_secret_names,
    'rls_disabled_tables', v_rls_disabled,
    'non_vehicle_anon_privileges', v_anon_privileges
  );
end;
$$;

revoke all on function public.rentmect_temporary_readiness_snapshot() from public, anon, authenticated;
grant execute on function public.rentmect_temporary_readiness_snapshot() to service_role;
