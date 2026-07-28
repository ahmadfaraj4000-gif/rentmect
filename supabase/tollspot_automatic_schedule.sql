-- Automatic TollSpot fleet and toll polling.
-- Required Vault secrets:
--   project_url
--   project_anon_key
--   rentmect_tollspot_sync_secret
--
-- The Edge Function also requires TOLLSPOT_SYNC_SECRET with the same value.
-- The admin Settings > Pricing & Billing switch can pause scheduled reads
-- without removing this job.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid)
from cron.job
where jobname in ('rentmect-tollspot-tolls', 'rentmect-tollspot-fleet');

-- Poll recent tolls every 30 minutes. Provider transaction IDs and rental
-- charge source references make repeated windows idempotent.
select cron.schedule(
  'rentmect-tollspot-tolls',
  '*/30 * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret from vault.decrypted_secrets
      where name = 'project_url' limit 1
    ) || '/functions/v1/tollspot-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'project_anon_key' limit 1
      ),
      'x-tollspot-sync-secret', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'rentmect_tollspot_sync_secret' limit 1
      )
    ),
    body := jsonb_build_object('action', 'sync_tolls')
  );
  $$
);

-- Reconcile fleet enrollment, plates, and assignments every six hours.
select cron.schedule(
  'rentmect-tollspot-fleet',
  '17 */6 * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret from vault.decrypted_secrets
      where name = 'project_url' limit 1
    ) || '/functions/v1/tollspot-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'project_anon_key' limit 1
      ),
      'x-tollspot-sync-secret', (
        select decrypted_secret from vault.decrypted_secrets
        where name = 'rentmect_tollspot_sync_secret' limit 1
      )
    ),
    body := jsonb_build_object('action', 'sync_fleet')
  );
  $$
);
