-- Queued Pushover alerts for bookings, document review, returns, and maintenance.
--
-- Before running this migration:
--   1. Deploy the notify-admin-events Edge Function.
--   2. Store PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY as Edge Function secrets.
--   3. Confirm Supabase Vault contains:
--        project_url      = https://YOUR_PROJECT_REF.supabase.co
--        project_anon_key = the project's anon/publishable JWT key

create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists public.admin_notification_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('new_booking', 'document_pending_review', 'return_due_today', 'maintenance_due')),
  source_id uuid not null,
  rental_id uuid,
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  sent_at timestamptz,
  provider_request_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists admin_notification_events_delivery_idx
  on public.admin_notification_events (status, next_attempt_at, created_at);

alter table public.admin_notification_events enable row level security;

drop policy if exists "Admins can read admin notification events" on public.admin_notification_events;
create policy "Admins can read admin notification events"
  on public.admin_notification_events
  for select
  to authenticated
  using (public.is_admin());

create or replace function public.queue_new_booking_admin_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.admin_notification_events (
    event_type, source_id, rental_id, dedupe_key
  ) values (
    'new_booking', new.id, new.id, 'new_booking:' || new.id::text
  ) on conflict (dedupe_key) do nothing;
  return new;
end;
$$;

drop trigger if exists rentals_queue_admin_notification on public.rentals;
create trigger rentals_queue_admin_notification
after insert on public.rentals
for each row execute function public.queue_new_booking_admin_notification();

create or replace function public.queue_document_review_admin_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_should_queue boolean := false;
  v_dedupe_key text;
begin
  if lower(coalesce(new.status, '')) <> 'pending_review' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_should_queue := true;
    v_dedupe_key := 'document_pending:' || new.id::text || ':initial';
  elsif old.status is distinct from new.status or old.file_path is distinct from new.file_path then
    v_should_queue := true;
    v_dedupe_key := 'document_pending:' || new.id::text || ':' || floor(extract(epoch from clock_timestamp()) * 1000000)::bigint::text;
  end if;

  if v_should_queue then
    insert into public.admin_notification_events (
      event_type, source_id, rental_id, dedupe_key
    ) values (
      'document_pending_review', new.id, new.rental_id, v_dedupe_key
    ) on conflict (dedupe_key) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists rental_documents_queue_admin_notification on public.rental_documents;
create trigger rental_documents_queue_admin_notification
after insert or update of status, file_path on public.rental_documents
for each row execute function public.queue_document_review_admin_notification();

create or replace function public.claim_admin_notification_events(p_limit integer default 20)
returns table (
  event_id uuid,
  event_type text,
  source_id uuid,
  rental_id uuid,
  attempts integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  return query
  with candidates as (
    select notification.id
    from public.admin_notification_events notification
    where notification.status in ('pending', 'failed')
      and notification.attempts < 5
      and notification.next_attempt_at <= now()
    order by notification.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  )
  update public.admin_notification_events notification
  set status = 'processing',
      attempts = notification.attempts + 1,
      updated_at = now()
  from candidates
  where notification.id = candidates.id
  returning notification.id,
            notification.event_type,
            notification.source_id,
            notification.rental_id,
            notification.attempts;
end;
$$;

revoke all on function public.claim_admin_notification_events(integer) from public;
grant execute on function public.claim_admin_notification_events(integer) to service_role;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-admin-pushover-notifications';

select cron.schedule(
  'rentmect-admin-pushover-notifications',
  '* * * * *',
  $$
  select net.http_post(
    url := (
      select decrypted_secret
      from vault.decrypted_secrets
      where name = 'project_url'
    ) || '/functions/v1/notify-admin-events',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret
        from vault.decrypted_secrets
        where name = 'project_anon_key'
      )
    ),
    body := '{}'::jsonb
  );
  $$
);
