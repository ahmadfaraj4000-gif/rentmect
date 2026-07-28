-- Hourly automatic Stripe security-deposit refunds.
-- Before running this schedule, store these Supabase Vault secrets:
--   project_url:                       https://YOUR_PROJECT_REF.supabase.co
--   project_anon_key:                  your Supabase anon/publishable key
--   rentmect_deposit_release_secret:   same value configured on the Edge
--                                       Function as RENTMECT_DEPOSIT_RELEASE_SECRET

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-security-deposit-release';

select cron.schedule(
  'rentmect-security-deposit-release',
  '7 * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'project_url'
    ) || '/functions/v1/stripe-web-hook',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'project_anon_key'
      ),
      'x-rentmect-deposit-secret', (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'rentmect_deposit_release_secret'
      )
    ),
    body := jsonb_build_object('action', 'release_due_deposits')
  );
  $$
);
