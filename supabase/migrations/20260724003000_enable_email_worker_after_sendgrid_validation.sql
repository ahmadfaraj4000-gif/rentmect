-- SendGrid accepted a controlled production delivery on 2026-07-24.
-- Enable the email worker only when its scheduler credentials are complete.

do $$
declare
  missing_secrets text[];
  email_job_id bigint;
begin
  select array_agg(required_secret.name order by required_secret.name)
  into missing_secrets
  from (
    values
      ('project_url'),
      ('project_anon_key'),
      ('rentmect_email_worker_secret')
  ) as required_secret(name)
  where not exists (
    select 1
    from vault.decrypted_secrets
    where vault.decrypted_secrets.name = required_secret.name
      and coalesce(vault.decrypted_secrets.decrypted_secret, '') <> ''
  );

  if coalesce(array_length(missing_secrets, 1), 0) > 0 then
    raise exception
      'Email worker remains disabled; missing Vault secrets: %',
      array_to_string(missing_secrets, ', ');
  end if;

  select jobid
  into email_job_id
  from cron.job
  where jobname = 'rentmect-email-worker-every-minute'
  limit 1;

  if email_job_id is null then
    raise exception
      'Email worker remains disabled; cron job rentmect-email-worker-every-minute does not exist.';
  end if;

  perform cron.alter_job(job_id := email_job_id, active := true);
end;
$$;
