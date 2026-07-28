-- Keep inventory cleanup self-healing: one sweep expires website holds,
-- unpaid customer/admin reservations, and unpaid approved continuations.

create extension if not exists pg_cron;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-expire-checkout-holds';

select cron.schedule(
  'rentmect-expire-checkout-holds',
  '* * * * *',
  $$select public.expire_stale_customer_checkout_holds();$$
);
