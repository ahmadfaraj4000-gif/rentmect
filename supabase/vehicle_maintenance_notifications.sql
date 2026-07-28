-- Vehicle odometer/service tracking plus queued Pushover alerts.
-- Run after rental_mileage_workflow.sql and admin_pushover_notifications.sql.

create extension if not exists pg_cron;

alter table public.vehicles
  add column if not exists original_mileage integer
    check (original_mileage is null or original_mileage >= 0),
  add column if not exists maintenance_interval_miles integer not null default 5000
    check (maintenance_interval_miles between 500 and 50000),
  add column if not exists last_maintenance_mileage integer
    check (last_maintenance_mileage is null or last_maintenance_mileage >= 0),
  add column if not exists next_maintenance_mileage integer
    check (next_maintenance_mileage is null or next_maintenance_mileage >= 0),
  add column if not exists maintenance_completed_at timestamptz;

update public.vehicles
set original_mileage = coalesce(original_mileage, current_mileage),
    last_maintenance_mileage = coalesce(last_maintenance_mileage, original_mileage, current_mileage),
    next_maintenance_mileage = coalesce(
      next_maintenance_mileage,
      last_maintenance_mileage + maintenance_interval_miles,
      original_mileage + maintenance_interval_miles,
      current_mileage + maintenance_interval_miles
    );

create or replace function public.set_vehicle_maintenance_schedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.original_mileage is null and new.current_mileage is not null then
    new.original_mileage := new.current_mileage;
  end if;
  if new.current_mileage is null and new.original_mileage is not null then
    new.current_mileage := new.original_mileage;
  end if;
  new.maintenance_interval_miles := coalesce(new.maintenance_interval_miles, 5000);
  if new.last_maintenance_mileage is null then
    new.last_maintenance_mileage := new.original_mileage;
  end if;

  if tg_op = 'INSERT' and new.next_maintenance_mileage is null then
    new.next_maintenance_mileage := coalesce(new.last_maintenance_mileage, new.original_mileage, new.current_mileage)
      + new.maintenance_interval_miles;
  elsif tg_op = 'UPDATE'
    and new.next_maintenance_mileage is not distinct from old.next_maintenance_mileage
    and (
      new.maintenance_interval_miles is distinct from old.maintenance_interval_miles
      or new.last_maintenance_mileage is distinct from old.last_maintenance_mileage
      or new.original_mileage is distinct from old.original_mileage
    ) then
    new.next_maintenance_mileage := coalesce(new.last_maintenance_mileage, new.original_mileage, new.current_mileage)
      + new.maintenance_interval_miles;
  end if;

  if new.current_mileage is not null and new.original_mileage is not null
    and new.current_mileage < new.original_mileage then
    raise exception 'Current mileage cannot be below original mileage.';
  end if;
  if new.last_maintenance_mileage is not null and new.current_mileage is not null
    and new.last_maintenance_mileage > new.current_mileage then
    raise exception 'Last maintenance mileage cannot exceed current mileage.';
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_set_maintenance_schedule on public.vehicles;
create trigger vehicles_set_maintenance_schedule
before insert or update of original_mileage, current_mileage, maintenance_interval_miles,
  last_maintenance_mileage, next_maintenance_mileage
on public.vehicles
for each row execute function public.set_vehicle_maintenance_schedule();

alter table public.admin_notification_events
  drop constraint if exists admin_notification_events_event_type_check;
alter table public.admin_notification_events
  add constraint admin_notification_events_event_type_check
  check (event_type in ('new_booking', 'document_pending_review', 'return_due_today',
    'maintenance_due', 'extension_requested', 'extension_approved'));

create or replace function public.queue_vehicle_maintenance_admin_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.current_mileage is null or new.next_maintenance_mileage is null
    or new.current_mileage < new.next_maintenance_mileage then
    return new;
  end if;

  if tg_op = 'UPDATE'
    and old.current_mileage is not null
    and old.next_maintenance_mileage is not null
    and old.current_mileage >= old.next_maintenance_mileage
    and old.next_maintenance_mileage is not distinct from new.next_maintenance_mileage then
    return new;
  end if;

  insert into public.admin_notification_events (
    event_type, source_id, rental_id, dedupe_key
  ) values (
    'maintenance_due', new.id, null,
    'maintenance_due:' || new.id::text || ':' || new.next_maintenance_mileage::text
  ) on conflict (dedupe_key) do nothing;
  return new;
end;
$$;

drop trigger if exists vehicles_queue_maintenance_notification on public.vehicles;
create trigger vehicles_queue_maintenance_notification
after insert or update of current_mileage, next_maintenance_mileage on public.vehicles
for each row execute function public.queue_vehicle_maintenance_admin_notification();

create or replace function public.queue_returns_due_today_admin_notifications()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_inserted integer := 0;
begin
  insert into public.admin_notification_events (
    event_type, source_id, rental_id, dedupe_key
  )
  select
    'return_due_today', rental.id, rental.id,
    'return_due_today:' || rental.id::text || ':' || v_today::text
  from public.rentals rental
  where rental.return_date = v_today
    and lower(coalesce(rental.status, '')) in ('active', 'overdue', 'return_initiated')
  on conflict (dedupe_key) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function public.queue_returns_due_today_admin_notifications() from public;
grant execute on function public.queue_returns_due_today_admin_notifications() to service_role;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-queue-returns-due-today';

select cron.schedule(
  'rentmect-queue-returns-due-today',
  '15 * * * *',
  $$select public.queue_returns_due_today_admin_notifications();$$
);
