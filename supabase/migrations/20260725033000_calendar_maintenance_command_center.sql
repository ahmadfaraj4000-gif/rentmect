-- Canonical fleet calendar and enforceable per-vehicle maintenance schedules.
-- This migration intentionally keeps existing rentals intact. Maintenance locks
-- stop new bookings and surface existing future reservations for admin review.

create extension if not exists pg_cron;

alter table public.admin_notification_events
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table public.admin_notification_events
  drop constraint if exists admin_notification_events_event_type_check;
alter table public.admin_notification_events
  add constraint admin_notification_events_event_type_check
  check (event_type in (
    'new_booking', 'document_pending_review', 'return_due_today',
    'maintenance_due', 'maintenance_due_soon', 'maintenance_override',
    'extension_requested', 'extension_approved', 'emergency_exception_created'
  ));

drop function if exists public.claim_admin_notification_events(integer);
create function public.claim_admin_notification_events(p_limit integer default 20)
returns table (
  event_id uuid,
  event_type text,
  source_id uuid,
  rental_id uuid,
  attempts integer,
  metadata jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
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
  returning notification.id, notification.event_type, notification.source_id,
    notification.rental_id, notification.attempts, notification.metadata;
end;
$$;
revoke all on function public.claim_admin_notification_events(integer) from public;
grant execute on function public.claim_admin_notification_events(integer) to service_role;

create table if not exists public.vehicle_maintenance_schedules (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  service_type text not null check (service_type in (
    'oil_change', 'tire_service', 'transmission_service',
    'brake_fluid', 'spark_plugs', 'coolant'
  )),
  label text not null,
  interval_miles integer check (interval_miles is null or interval_miles between 500 and 300000),
  interval_months integer check (interval_months is null or interval_months between 1 and 240),
  warning_miles integer not null default 500 check (warning_miles between 0 and 25000),
  warning_days integer not null default 30 check (warning_days between 0 and 365),
  last_service_mileage integer check (last_service_mileage is null or last_service_mileage >= 0),
  last_service_at date,
  next_due_mileage integer check (next_due_mileage is null or next_due_mileage >= 0),
  next_due_at date,
  lock_when_due boolean not null default true,
  active boolean not null default true,
  source text not null default 'oem_default' check (source in ('oem_default', 'admin_custom')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (vehicle_id, service_type),
  check (interval_miles is not null or interval_months is not null)
);

create table if not exists public.vehicle_maintenance_service_logs (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  schedule_id uuid not null references public.vehicle_maintenance_schedules(id) on delete restrict,
  service_type text not null,
  completed_mileage integer not null check (completed_mileage >= 0),
  completed_at date not null,
  notes text,
  completed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists vehicle_maintenance_schedules_vehicle_idx
  on public.vehicle_maintenance_schedules (vehicle_id, active);
create index if not exists vehicle_maintenance_schedules_due_mileage_idx
  on public.vehicle_maintenance_schedules (next_due_mileage) where active;
create index if not exists vehicle_maintenance_schedules_due_date_idx
  on public.vehicle_maintenance_schedules (next_due_at) where active;
create index if not exists vehicle_maintenance_service_logs_vehicle_idx
  on public.vehicle_maintenance_service_logs (vehicle_id, completed_at desc);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pending_bookings'
  ) then alter publication supabase_realtime add table public.pending_bookings; end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'vehicles'
  ) then alter publication supabase_realtime add table public.vehicles; end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'vehicle_maintenance_schedules'
  ) then alter publication supabase_realtime add table public.vehicle_maintenance_schedules; end if;
end $$;

alter table public.vehicle_maintenance_schedules enable row level security;
alter table public.vehicle_maintenance_service_logs enable row level security;

drop policy if exists "Admins manage vehicle maintenance schedules" on public.vehicle_maintenance_schedules;
create policy "Admins manage vehicle maintenance schedules"
  on public.vehicle_maintenance_schedules for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins read vehicle maintenance service logs" on public.vehicle_maintenance_service_logs;
create policy "Admins read vehicle maintenance service logs"
  on public.vehicle_maintenance_service_logs for select to authenticated
  using (public.is_admin());

alter table public.vehicles
  add column if not exists maintenance_lock_active boolean not null default false,
  add column if not exists maintenance_lock_reason text,
  add column if not exists maintenance_lock_schedule_id uuid references public.vehicle_maintenance_schedules(id) on delete set null,
  add column if not exists maintenance_locked_at timestamptz,
  add column if not exists maintenance_prelock_status text,
  add column if not exists maintenance_override_until timestamptz,
  add column if not exists maintenance_override_reason text,
  add column if not exists maintenance_override_admin_id uuid references public.profiles(id) on delete set null;

create or replace function public.set_vehicle_maintenance_schedule_due_values()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.label := nullif(trim(new.label), '');
  if new.label is null then raise exception 'Maintenance label is required.'; end if;
  new.next_due_mileage := case
    when new.interval_miles is null or new.last_service_mileage is null then null
    else new.last_service_mileage + new.interval_miles
  end;
  new.next_due_at := case
    when new.interval_months is null or new.last_service_at is null then null
    else (new.last_service_at + make_interval(months => new.interval_months))::date
  end;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists vehicle_maintenance_schedule_due_values on public.vehicle_maintenance_schedules;
create trigger vehicle_maintenance_schedule_due_values
before insert or update of label, interval_miles, interval_months,
  last_service_mileage, last_service_at
on public.vehicle_maintenance_schedules
for each row execute function public.set_vehicle_maintenance_schedule_due_values();

create or replace function public.rentmect_oem_mileage_interval(
  p_vehicle text,
  p_service_type text
) returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := lower(coalesce(p_vehicle, ''));
begin
  if p_service_type = 'brake_fluid' then return null; end if;

  if v like '%ford%escape%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 150000 when 'spark_plugs' then 100000 when 'coolant' then 200000 end;
  elsif v like '%kia%soul%' then
    return case p_service_type when 'oil_change' then 6000 when 'tire_service' then 6000
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  elsif v like '%buick%encore%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 45000 when 'spark_plugs' then 97000 when 'coolant' then 150000 end;
  elsif v ~ '(^|[^a-z])audi([^a-z]|$)' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 40000 when 'spark_plugs' then 55000 when 'coolant' then 100000 end;
  elsif v like '%bmw%' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 60000 when 'spark_plugs' then 60000 when 'coolant' then 100000 end;
  elsif v like '%mercedes%' or v like '%benz%' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 60000 when 'spark_plugs' then 60000 when 'coolant' then 100000 end;
  elsif v like '%cadillac%ats%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 45000 when 'spark_plugs' then 97000 when 'coolant' then 150000 end;
  elsif v like '%dodge%van%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  elsif v like '%ford%f350%' or v like '%ford%f-350%' then
    return case p_service_type when 'oil_change' then 5000 when 'tire_service' then 5000
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  end if;

  return case p_service_type when 'oil_change' then 5000 when 'tire_service' then 7500
    when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
end;
$$;

create or replace function public.rentmect_oem_month_interval(
  p_vehicle text,
  p_service_type text
) returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := lower(coalesce(p_vehicle, ''));
begin
  if p_service_type <> 'brake_fluid' then return null; end if;
  if v like '%kia%soul%' then return 60; end if;
  if v ~ '(^|[^a-z])audi([^a-z]|$)' or v like '%bmw%' or v like '%mercedes%' or v like '%benz%' then return 24; end if;
  return 36;
end;
$$;

insert into public.vehicle_maintenance_schedules (
  vehicle_id, service_type, label, interval_miles, interval_months,
  warning_miles, warning_days, last_service_mileage, last_service_at,
  lock_when_due, source
)
select
  vehicles.id,
  service.service_type,
  service.label,
  public.rentmect_oem_mileage_interval(
    concat_ws(' ', vehicles.brand, vehicles.model, vehicles.name),
    service.service_type
  ),
  public.rentmect_oem_month_interval(
    concat_ws(' ', vehicles.brand, vehicles.model, vehicles.name),
    service.service_type
  ),
  service.warning_miles,
  service.warning_days,
  case when service.service_type = 'oil_change'
    then coalesce(vehicles.last_maintenance_mileage, vehicles.current_mileage, vehicles.original_mileage, 0)
    else coalesce(vehicles.current_mileage, vehicles.original_mileage, 0)
  end,
  case when service.service_type = 'oil_change'
    then coalesce(vehicles.maintenance_completed_at::date, current_date)
    else current_date
  end,
  true,
  'oem_default'
from public.vehicles
cross join (values
  ('oil_change', 'Oil change', 500, 14),
  ('tire_service', 'Tire rotation / inspection', 750, 30),
  ('transmission_service', 'Transmission service', 5000, 60),
  ('brake_fluid', 'Brake fluid service', 0, 60),
  ('spark_plugs', 'Spark plug replacement', 5000, 60),
  ('coolant', 'Coolant service', 5000, 60)
) as service(service_type, label, warning_miles, warning_days)
on conflict (vehicle_id, service_type) do nothing;

create or replace function public.install_default_vehicle_maintenance_schedules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.vehicle_maintenance_schedules (
    vehicle_id, service_type, label, interval_miles, interval_months,
    warning_miles, warning_days, last_service_mileage, last_service_at,
    lock_when_due, source
  )
  select
    new.id, service.service_type, service.label,
    public.rentmect_oem_mileage_interval(
      concat_ws(' ', new.brand, new.model, new.name), service.service_type
    ),
    public.rentmect_oem_month_interval(
      concat_ws(' ', new.brand, new.model, new.name), service.service_type
    ),
    service.warning_miles, service.warning_days,
    coalesce(new.current_mileage, new.original_mileage, 0), current_date,
    true, 'oem_default'
  from (values
    ('oil_change', 'Oil change', 500, 14),
    ('tire_service', 'Tire rotation / inspection', 750, 30),
    ('transmission_service', 'Transmission service', 5000, 60),
    ('brake_fluid', 'Brake fluid service', 0, 60),
    ('spark_plugs', 'Spark plug replacement', 5000, 60),
    ('coolant', 'Coolant service', 5000, 60)
  ) as service(service_type, label, warning_miles, warning_days)
  on conflict (vehicle_id, service_type) do nothing;
  return new;
end;
$$;

drop trigger if exists vehicles_install_default_maintenance_schedules on public.vehicles;
create trigger vehicles_install_default_maintenance_schedules
after insert on public.vehicles
for each row execute function public.install_default_vehicle_maintenance_schedules();

create or replace function public.evaluate_vehicle_maintenance(
  p_vehicle_id uuid
) returns public.vehicles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle public.vehicles%rowtype;
  v_due public.vehicle_maintenance_schedules%rowtype;
  v_soon public.vehicle_maintenance_schedules%rowtype;
  v_override_active boolean;
begin
  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;

  v_override_active := v_vehicle.maintenance_override_until is not null
    and v_vehicle.maintenance_override_until > now();

  select schedule.* into v_due
  from public.vehicle_maintenance_schedules schedule
  where schedule.vehicle_id = p_vehicle_id
    and schedule.active and schedule.lock_when_due
    and (
      (schedule.next_due_mileage is not null and v_vehicle.current_mileage is not null
        and v_vehicle.current_mileage >= schedule.next_due_mileage)
      or (schedule.next_due_at is not null and current_date >= schedule.next_due_at)
    )
  order by
    case schedule.service_type when 'oil_change' then 1 when 'tire_service' then 2 else 3 end,
    least(
      coalesce(schedule.next_due_at, '9999-12-31'::date),
      current_date + greatest(coalesce(schedule.next_due_mileage - v_vehicle.current_mileage, 999999), 0)
    )
  limit 1;

  if v_due.id is not null and not v_override_active then
    update public.vehicles
    set maintenance_prelock_status = case
          when not coalesce(maintenance_lock_active, false) and lower(coalesce(status, 'available')) <> 'maintenance'
            then status
          else maintenance_prelock_status
        end,
        maintenance_lock_active = true,
        maintenance_lock_reason = v_due.label || ' due'
          || case when v_due.next_due_mileage is not null then ' at ' || v_due.next_due_mileage::text || ' miles' else '' end
          || case when v_due.next_due_at is not null then ' by ' || v_due.next_due_at::text else '' end,
        maintenance_lock_schedule_id = v_due.id,
        maintenance_locked_at = coalesce(maintenance_locked_at, now()),
        maintenance_override_until = null,
        maintenance_override_reason = null,
        maintenance_override_admin_id = null,
        status = 'maintenance'
    where id = p_vehicle_id
    returning * into v_vehicle;

    insert into public.admin_notification_events (
      event_type, source_id, rental_id, dedupe_key, metadata
    ) values (
      'maintenance_due', v_due.id, null,
      'maintenance_due:' || v_due.id::text || ':'
        || coalesce(v_due.next_due_mileage::text, v_due.next_due_at::text, 'due'),
      jsonb_build_object('vehicle_id', p_vehicle_id, 'service_type', v_due.service_type)
    ) on conflict (dedupe_key) do nothing;
  elsif v_due.id is null and (
    coalesce(v_vehicle.maintenance_lock_active, false)
    or v_vehicle.maintenance_override_until is not null
  ) then
    update public.vehicles
    set maintenance_lock_active = false,
        maintenance_lock_reason = null,
        maintenance_lock_schedule_id = null,
        maintenance_locked_at = null,
        maintenance_override_until = null,
        maintenance_override_reason = null,
        maintenance_override_admin_id = null,
        status = case when lower(coalesce(status, '')) = 'maintenance'
          then coalesce(nullif(maintenance_prelock_status, 'maintenance'), 'available')
          else status end,
        maintenance_prelock_status = null
    where id = p_vehicle_id
    returning * into v_vehicle;
  end if;

  select schedule.* into v_soon
  from public.vehicle_maintenance_schedules schedule
  where schedule.vehicle_id = p_vehicle_id and schedule.active
    and not (
      (schedule.next_due_mileage is not null and v_vehicle.current_mileage is not null
        and v_vehicle.current_mileage >= schedule.next_due_mileage)
      or (schedule.next_due_at is not null and current_date >= schedule.next_due_at)
    )
    and (
      (schedule.next_due_mileage is not null and v_vehicle.current_mileage is not null
        and schedule.next_due_mileage - v_vehicle.current_mileage <= schedule.warning_miles)
      or (schedule.next_due_at is not null and schedule.next_due_at - current_date <= schedule.warning_days)
    )
  order by coalesce(schedule.next_due_mileage - v_vehicle.current_mileage, 999999),
    coalesce(schedule.next_due_at - current_date, 999999)
  limit 1;

  if v_soon.id is not null then
    insert into public.admin_notification_events (
      event_type, source_id, rental_id, dedupe_key, metadata
    ) values (
      'maintenance_due_soon', v_soon.id, null,
      'maintenance_due_soon:' || v_soon.id::text || ':'
        || coalesce(v_soon.next_due_mileage::text, v_soon.next_due_at::text, 'soon'),
      jsonb_build_object('vehicle_id', p_vehicle_id, 'service_type', v_soon.service_type)
    ) on conflict (dedupe_key) do nothing;
  end if;

  return v_vehicle;
end;
$$;

revoke all on function public.evaluate_vehicle_maintenance(uuid) from public;
grant execute on function public.evaluate_vehicle_maintenance(uuid) to service_role;

create or replace function public.evaluate_vehicle_maintenance_after_mileage()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.evaluate_vehicle_maintenance(new.id);
  return new;
end;
$$;

drop trigger if exists vehicles_evaluate_maintenance_after_mileage on public.vehicles;
create trigger vehicles_evaluate_maintenance_after_mileage
after insert or update of current_mileage, next_maintenance_mileage
on public.vehicles
for each row execute function public.evaluate_vehicle_maintenance_after_mileage();

create or replace function public.evaluate_vehicle_maintenance_after_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.evaluate_vehicle_maintenance(old.vehicle_id);
    return old;
  end if;
  perform public.evaluate_vehicle_maintenance(new.vehicle_id);
  return new;
end;
$$;

drop trigger if exists maintenance_schedule_evaluate_vehicle on public.vehicle_maintenance_schedules;
create trigger maintenance_schedule_evaluate_vehicle
after insert or update or delete on public.vehicle_maintenance_schedules
for each row execute function public.evaluate_vehicle_maintenance_after_schedule();

create or replace function public.enforce_vehicle_maintenance_lock()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(old.maintenance_lock_active, false)
     and coalesce(new.maintenance_lock_active, false)
     and lower(coalesce(new.status, 'available')) <> 'maintenance'
     and not (old.maintenance_override_until is not null and old.maintenance_override_until > now()) then
    raise exception 'This vehicle is locked for required maintenance. Complete service or create an audited maintenance override.';
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_enforce_maintenance_lock on public.vehicles;
create trigger vehicles_enforce_maintenance_lock
before update of status on public.vehicles
for each row execute function public.enforce_vehicle_maintenance_lock();

create or replace function public.enforce_rental_odometer_gate()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_status text := lower(coalesce(new.status, ''));
begin
  if v_status in ('active', 'overdue', 'return_initiated')
     and new.starting_mileage is null then
    raise exception 'Starting mileage is mandatory before a vehicle can leave the lot.';
  end if;
  if v_status = 'active'
     and (tg_op = 'INSERT' or lower(coalesce(old.status, '')) <> 'active')
     and exists (
       select 1
       from public.vehicles vehicle
       join public.vehicle_maintenance_schedules schedule on schedule.vehicle_id = vehicle.id
       where vehicle.id = new.vehicle_id
         and schedule.active and schedule.lock_when_due
         and not (vehicle.maintenance_override_until is not null and vehicle.maintenance_override_until > now())
         and (
           (schedule.next_due_mileage is not null and new.starting_mileage >= schedule.next_due_mileage)
           or (schedule.next_due_at is not null and current_date >= schedule.next_due_at)
         )
     ) then
    raise exception 'Required maintenance is due at this odometer reading. Complete service or create an audited override before releasing the vehicle.';
  end if;
  if v_status = 'completed' and new.ending_mileage is null then
    raise exception 'Ending mileage is mandatory before a returned vehicle can be closed.';
  end if;
  if new.starting_mileage is not null and new.ending_mileage is not null
     and new.ending_mileage < new.starting_mileage then
    raise exception 'Ending mileage cannot be below starting mileage.';
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_enforce_odometer_gate on public.rentals;
create trigger rentals_enforce_odometer_gate
before insert or update of status, starting_mileage, ending_mileage
on public.rentals
for each row execute function public.enforce_rental_odometer_gate();

create or replace function public.admin_complete_vehicle_service(
  p_schedule_id uuid,
  p_completed_mileage integer,
  p_completed_at date default current_date,
  p_notes text default null
) returns public.vehicle_maintenance_schedules
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_schedule public.vehicle_maintenance_schedules%rowtype;
  v_vehicle public.vehicles%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_completed_mileage is null or p_completed_mileage < 0 then raise exception 'Service mileage is required.'; end if;
  if p_completed_at is null or p_completed_at > current_date then raise exception 'Enter a valid service date.'; end if;

  select * into v_schedule from public.vehicle_maintenance_schedules where id = p_schedule_id for update;
  if not found then raise exception 'Maintenance schedule not found.'; end if;
  select * into v_vehicle from public.vehicles where id = v_schedule.vehicle_id for update;
  if p_completed_mileage < coalesce(v_vehicle.current_mileage, 0) then
    raise exception 'Service mileage cannot be below the vehicle current mileage (%).', v_vehicle.current_mileage;
  end if;

  update public.vehicles set current_mileage = p_completed_mileage where id = v_vehicle.id;
  update public.vehicle_maintenance_schedules
  set last_service_mileage = case when interval_miles is null then last_service_mileage else p_completed_mileage end,
      last_service_at = case when interval_months is null then last_service_at else p_completed_at end,
      notes = coalesce(nullif(trim(p_notes), ''), notes),
      source = 'admin_custom'
  where id = p_schedule_id
  returning * into v_schedule;

  insert into public.vehicle_maintenance_service_logs (
    vehicle_id, schedule_id, service_type, completed_mileage, completed_at, notes, completed_by
  ) values (
    v_schedule.vehicle_id, v_schedule.id, v_schedule.service_type,
    p_completed_mileage, p_completed_at, nullif(trim(p_notes), ''), v_admin_id
  );

  if v_schedule.service_type = 'oil_change' then
    update public.vehicles
    set last_maintenance_mileage = p_completed_mileage,
        next_maintenance_mileage = v_schedule.next_due_mileage,
        maintenance_interval_miles = coalesce(v_schedule.interval_miles, maintenance_interval_miles),
        maintenance_completed_at = p_completed_at::timestamptz
    where id = v_schedule.vehicle_id;
  end if;

  perform public.evaluate_vehicle_maintenance(v_schedule.vehicle_id);
  perform public.record_admin_audit_event(
    'vehicle.maintenance_completed', 'vehicle', v_schedule.vehicle_id::text,
    jsonb_build_object(
      'schedule_id', v_schedule.id, 'service_type', v_schedule.service_type,
      'completed_mileage', p_completed_mileage, 'completed_at', p_completed_at,
      'notes', nullif(trim(p_notes), '')
    )
  );
  return v_schedule;
end;
$$;

revoke all on function public.admin_complete_vehicle_service(uuid, integer, date, text) from public;
grant execute on function public.admin_complete_vehicle_service(uuid, integer, date, text) to authenticated;

create or replace function public.admin_override_vehicle_maintenance(
  p_vehicle_id uuid,
  p_reason text,
  p_hours integer default 24
) returns public.vehicles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_vehicle public.vehicles%rowtype;
  v_until timestamptz;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then raise exception 'Enter a specific override reason (at least 10 characters).'; end if;
  if p_hours < 1 or p_hours > 168 then raise exception 'Override duration must be between 1 and 168 hours.'; end if;

  select * into v_vehicle from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if not coalesce(v_vehicle.maintenance_lock_active, false) then
    raise exception 'This vehicle does not have an active automatic maintenance lock.';
  end if;

  v_until := now() + make_interval(hours => p_hours);
  update public.vehicles
  set maintenance_lock_active = false,
      maintenance_override_until = v_until,
      maintenance_override_reason = trim(p_reason),
      maintenance_override_admin_id = v_admin_id,
      status = coalesce(nullif(maintenance_prelock_status, 'maintenance'), 'available')
  where id = p_vehicle_id
  returning * into v_vehicle;

  insert into public.admin_notification_events (
    event_type, source_id, rental_id, dedupe_key, metadata
  ) values (
    'maintenance_override', p_vehicle_id, null,
    'maintenance_override:' || p_vehicle_id::text || ':' || floor(extract(epoch from v_until))::bigint::text,
    jsonb_build_object('vehicle_id', p_vehicle_id, 'until', v_until, 'reason', trim(p_reason), 'admin_id', v_admin_id)
  ) on conflict (dedupe_key) do nothing;

  perform public.record_admin_audit_event(
    'vehicle.maintenance_override', 'vehicle', p_vehicle_id::text,
    jsonb_build_object('until', v_until, 'reason', trim(p_reason), 'hours', p_hours)
  );
  return v_vehicle;
end;
$$;

revoke all on function public.admin_override_vehicle_maintenance(uuid, text, integer) from public;
grant execute on function public.admin_override_vehicle_maintenance(uuid, text, integer) to authenticated;

create or replace function public.admin_save_vehicle_maintenance_schedule(
  p_schedule_id uuid,
  p_vehicle_id uuid,
  p_service_type text,
  p_label text,
  p_interval_miles integer,
  p_interval_months integer,
  p_warning_miles integer,
  p_warning_days integer,
  p_last_service_mileage integer,
  p_last_service_at date,
  p_lock_when_due boolean,
  p_active boolean,
  p_notes text default null
) returns public.vehicle_maintenance_schedules
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_schedule public.vehicle_maintenance_schedules%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_interval_miles is null and p_interval_months is null then
    raise exception 'Set a mileage or time interval.';
  end if;

  insert into public.vehicle_maintenance_schedules (
    id, vehicle_id, service_type, label, interval_miles, interval_months,
    warning_miles, warning_days, last_service_mileage, last_service_at,
    lock_when_due, active, source, notes
  ) values (
    coalesce(p_schedule_id, gen_random_uuid()), p_vehicle_id, p_service_type, trim(p_label),
    p_interval_miles, p_interval_months, coalesce(p_warning_miles, 0),
    coalesce(p_warning_days, 0), p_last_service_mileage, p_last_service_at,
    coalesce(p_lock_when_due, true), coalesce(p_active, true), 'admin_custom',
    nullif(trim(p_notes), '')
  )
  on conflict (vehicle_id, service_type) do update set
    label = excluded.label,
    interval_miles = excluded.interval_miles,
    interval_months = excluded.interval_months,
    warning_miles = excluded.warning_miles,
    warning_days = excluded.warning_days,
    last_service_mileage = excluded.last_service_mileage,
    last_service_at = excluded.last_service_at,
    lock_when_due = excluded.lock_when_due,
    active = excluded.active,
    source = 'admin_custom',
    notes = excluded.notes
  returning * into v_schedule;

  perform public.record_admin_audit_event(
    'vehicle.maintenance_schedule_updated', 'vehicle', p_vehicle_id::text,
    jsonb_build_object('schedule_id', v_schedule.id, 'service_type', v_schedule.service_type)
  );
  return v_schedule;
end;
$$;

revoke all on function public.admin_save_vehicle_maintenance_schedule(
  uuid, uuid, text, text, integer, integer, integer, integer,
  integer, date, boolean, boolean, text
) from public;
grant execute on function public.admin_save_vehicle_maintenance_schedule(
  uuid, uuid, text, text, integer, integer, integer, integer,
  integer, date, boolean, boolean, text
) to authenticated;

create or replace function public.get_admin_calendar_events(
  p_start_date date,
  p_end_date date
) returns table (
  id uuid,
  vehicle_id uuid,
  start_date date,
  end_date date,
  start_time text,
  end_time text,
  event_type text,
  status text,
  label text,
  customer_name text,
  source_id uuid,
  expires_at timestamptz,
  notes text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date
     or p_end_date - p_start_date > 120 then raise exception 'Choose a valid calendar window of 120 days or less.'; end if;

  return query
  select rental.id, rental.vehicle_id, rental.pickup_date, rental.return_date,
    rental.pickup_time, rental.return_time, 'rental'::text, rental.status,
    case when rental.booking_source in ('admin_manual', 'admin') then 'Admin booking' else 'Customer booking' end,
    coalesce(profile.full_name, profile.email, 'Customer'), rental.id, rental.checkout_expires_at,
    rental.admin_notes
  from public.rentals rental
  left join public.profiles profile on profile.id = rental.user_id
  where rental.vehicle_id is not null
    and lower(coalesce(rental.status, '')) <> 'cancelled'
    and rental.pickup_date <= p_end_date and rental.return_date >= p_start_date

  union all

  select booking.id, booking.vehicle_id, booking.pickup_date, booking.return_date,
    booking.pickup_time, booking.return_time, 'checkout_hold'::text, 'checkout_hold'::text,
    'Website checkout hold', coalesce(booking.customer_email, 'Customer checking out'),
    booking.id, booking.expires_at, null::text
  from public.pending_bookings booking
  where lower(coalesce(booking.status, 'pending')) = 'pending'
    and booking.expires_at > now() and booking.vehicle_id is not null
    and booking.pickup_date <= p_end_date and booking.return_date >= p_start_date

  union all

  select block.id, block.vehicle_id, block.start_date, block.end_date,
    block.start_time, block.end_time, 'manual_block'::text, block.block_type,
    coalesce(block.label, initcap(replace(block.block_type, '_', ' '))), null::text,
    block.id, null::timestamptz, block.notes
  from public.vehicle_availability_blocks block
  where coalesce(block.active, true)
    and lower(coalesce(block.block_type, 'unavailable')) <> 'available'
    and block.start_date <= p_end_date and block.end_date >= p_start_date

  union all

  select vehicle.id, vehicle.id, p_start_date, p_end_date,
    '12:00 AM'::text, '11:59 PM'::text, 'maintenance_lock'::text, 'maintenance'::text,
    coalesce(vehicle.maintenance_lock_reason, 'Maintenance'), null::text,
    vehicle.maintenance_lock_schedule_id, vehicle.maintenance_override_until,
    vehicle.maintenance_override_reason
  from public.vehicles vehicle
  where coalesce(vehicle.maintenance_lock_active, false)
     or lower(coalesce(vehicle.status, '')) in ('maintenance', 'unavailable', 'inactive');
end;
$$;

revoke all on function public.get_admin_calendar_events(date, date) from public;
grant execute on function public.get_admin_calendar_events(date, date) to authenticated;

create or replace function public.evaluate_all_vehicle_maintenance()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle record;
  v_count integer := 0;
begin
  for v_vehicle in select id from public.vehicles loop
    perform public.evaluate_vehicle_maintenance(v_vehicle.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.evaluate_all_vehicle_maintenance() from public;
grant execute on function public.evaluate_all_vehicle_maintenance() to service_role;

select cron.unschedule(jobid)
from cron.job
where jobname = 'rentmect-evaluate-vehicle-maintenance';

select cron.schedule(
  'rentmect-evaluate-vehicle-maintenance',
  '*/15 * * * *',
  $$select public.evaluate_all_vehicle_maintenance();$$
);

select public.evaluate_all_vehicle_maintenance();
