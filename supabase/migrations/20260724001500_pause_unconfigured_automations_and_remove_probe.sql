-- Keep unconfigured production workers from failing silently or taking
-- untested financial action. Re-enable after their provider/secret acceptance
-- tests pass.

do $$
declare
  scheduled_job record;
begin
  for scheduled_job in
    select jobid
    from cron.job
    where jobname in (
      'rentmect-email-worker-every-minute',
      'rentmect-security-deposit-release'
    )
  loop
    perform cron.alter_job(job_id := scheduled_job.jobid, active := false);
  end loop;
end;
$$;

drop function if exists public.rentmect_temporary_readiness_snapshot();
