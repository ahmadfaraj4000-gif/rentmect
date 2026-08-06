-- Keep the frequent sync incremental while retaining a slower reconciliation
-- pass for provider records that post late.

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-tollspot-weekly-reconciliation';

select cron.schedule(
  'rentmect-tollspot-weekly-reconciliation',
  '23 3 * * 0',
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
    body := jsonb_build_object('action', 'backfill_tolls')
  );
  $$
);
