-- Automated customer return SMS and admin paid-rental alert schedule for
-- send-rental-due-reminders.
-- Keep this for the scheduled Supabase environment. Local testing can use the
-- admin Rentals SMS button or invoke the Edge Function manually.
--
-- Before running this file, store these Vault secrets:
--   project_url:              https://YOUR_PROJECT_REF.supabase.co
--   project_anon_key:         your Supabase anon key
--   rentmect_reminder_secret: same value as the Edge Function secret
--                              RENTMECT_REMINDER_SECRET

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-return-due-sms-reminders';

select cron.schedule(
  'rentmect-return-due-sms-reminders',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'project_url'
    ) || '/functions/v1/send-rental-due-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'project_anon_key'
      ),
      'x-rentmect-reminder-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'rentmect_reminder_secret'
      )
    ),
    body := '{}'::jsonb
  );
  $$
);
