-- Optional one-minute worker schedule. Run after email_automation_and_campaigns.sql.
-- Vault secrets required:
--   project_url
--   project_anon_key
--   rentmect_email_worker_secret (must match RENTMECT_EMAIL_WORKER_SECRET on the Edge Function)

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'rentmect-email-worker-every-minute') then
    perform cron.unschedule('rentmect-email-worker-every-minute');
  end if;
end $$;

select cron.schedule(
  'rentmect-email-worker-every-minute',
  '* * * * *',
  $schedule$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url' limit 1)
      || '/functions/v1/send-emails/process',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'project_anon_key' limit 1),
      'x-rentmect-email-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'rentmect_email_worker_secret' limit 1)
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $schedule$
);
