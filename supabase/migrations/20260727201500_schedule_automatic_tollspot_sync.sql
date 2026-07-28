-- Keep TollSpot tolls and fleet enrollment synchronized without admin work.
-- These Vault secrets are provisioned alongside the corresponding Edge
-- Function secrets and are intentionally not stored in source control.

create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists pgcrypto;

-- The scheduler credential is generated inside Postgres so it never needs to
-- be copied by an administrator or committed to a migration.
do $$
begin
  if not exists (
    select 1
    from vault.decrypted_secrets
    where name = 'rentmect_tollspot_sync_secret'
      and nullif(decrypted_secret, '') is not null
  ) then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'rentmect_tollspot_sync_secret',
      'Authenticates automatic TollSpot pg_cron requests'
    );
  end if;
end
$$;

create or replace function public.verify_tollspot_sync_secret(
  p_secret text
)
returns boolean
language sql
stable
security definer
set search_path = public, vault
as $$
  select exists (
    select 1
    from vault.decrypted_secrets
    where name = 'rentmect_tollspot_sync_secret'
      and length(coalesce(p_secret, '')) > 0
      and decrypted_secret = p_secret
  );
$$;

revoke all on function public.verify_tollspot_sync_secret(text) from public;
revoke all on function public.verify_tollspot_sync_secret(text) from anon;
revoke all on function public.verify_tollspot_sync_secret(text) from authenticated;
grant execute on function public.verify_tollspot_sync_secret(text) to service_role;

do $$
declare
  missing_secret text;
begin
  select required.name
  into missing_secret
  from (
    values
      ('project_url'),
      ('project_anon_key'),
      ('rentmect_tollspot_sync_secret')
  ) as required(name)
  where not exists (
    select 1
    from vault.decrypted_secrets secret
    where secret.name = required.name
      and nullif(secret.decrypted_secret, '') is not null
  )
  limit 1;

  if missing_secret is not null then
    raise exception 'Required TollSpot scheduler Vault secret is missing: %',
      missing_secret;
  end if;
end
$$;

select cron.unschedule(jobid)
from cron.job
where jobname in ('rentmect-tollspot-tolls', 'rentmect-tollspot-fleet');

-- Provider transaction IDs and rental charge source references make the
-- overlapping transaction windows idempotent.
select cron.schedule(
  'rentmect-tollspot-tolls',
  '*/30 * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'project_url'
      limit 1
    ) || '/functions/v1/tollspot-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'project_anon_key'
        limit 1
      ),
      'x-tollspot-sync-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'rentmect_tollspot_sync_secret'
        limit 1
      )
    ),
    body := jsonb_build_object('action', 'sync_tolls')
  );
  $$
);

select cron.schedule(
  'rentmect-tollspot-fleet',
  '17 */6 * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'project_url'
      limit 1
    ) || '/functions/v1/tollspot-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'project_anon_key'
        limit 1
      ),
      'x-tollspot-sync-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'rentmect_tollspot_sync_secret'
        limit 1
      )
    ),
    body := jsonb_build_object('action', 'sync_fleet')
  );
  $$
);
