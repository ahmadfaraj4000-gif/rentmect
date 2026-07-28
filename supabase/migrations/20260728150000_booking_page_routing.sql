-- Admin-controlled public booking-page routing.
-- Wheelbase is the fail-safe default. Scheduled changes are evaluated against
-- the database clock, so no browser or admin session has to remain open.

create table if not exists public.booking_page_settings (
  id boolean primary key default true check (id = true),
  active_provider text not null default 'wheelbase'
    check (active_provider in ('wheelbase', 'supabase')),
  scheduled_provider text
    check (scheduled_provider is null or scheduled_provider in ('wheelbase', 'supabase')),
  scheduled_at timestamptz,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  check (
    (scheduled_provider is null and scheduled_at is null)
    or
    (scheduled_provider is not null and scheduled_at is not null)
  )
);

insert into public.booking_page_settings (id, active_provider)
values (true, 'wheelbase')
on conflict (id) do nothing;

alter table public.booking_page_settings enable row level security;

drop policy if exists "Admins can read booking page settings" on public.booking_page_settings;
create policy "Admins can read booking page settings"
on public.booking_page_settings
for select
to authenticated
using (public.is_admin());

revoke all on public.booking_page_settings from anon, authenticated;
grant select on public.booking_page_settings to authenticated;

create or replace function public.get_public_booking_page_setting()
returns table (
  provider text,
  page_path text,
  scheduled_provider text,
  scheduled_page_path text,
  scheduled_at timestamptz,
  server_now timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    case
      when settings.scheduled_at is not null and settings.scheduled_at <= now()
        then settings.scheduled_provider
      else settings.active_provider
    end as provider,
    case
      when settings.scheduled_at is not null and settings.scheduled_at <= now()
        then case settings.scheduled_provider
          when 'supabase' then 'cars-2.html'
          else 'cars.html'
        end
      else case settings.active_provider
        when 'supabase' then 'cars-2.html'
        else 'cars.html'
      end
    end as page_path,
    case
      when settings.scheduled_at is not null and settings.scheduled_at > now()
        then settings.scheduled_provider
      else null
    end as scheduled_provider,
    case
      when settings.scheduled_at is not null and settings.scheduled_at > now()
        then case settings.scheduled_provider
          when 'supabase' then 'cars-2.html'
          else 'cars.html'
        end
      else null
    end as scheduled_page_path,
    case
      when settings.scheduled_at is not null and settings.scheduled_at > now()
        then settings.scheduled_at
      else null
    end as scheduled_at,
    now() as server_now
  from public.booking_page_settings as settings
  where settings.id = true;
$$;

revoke all on function public.get_public_booking_page_setting() from public;
grant execute on function public.get_public_booking_page_setting() to anon, authenticated;

create or replace function public.get_admin_booking_page_setting()
returns table (
  active_provider text,
  scheduled_provider text,
  scheduled_at timestamptz,
  effective_provider text,
  updated_by uuid,
  updated_at timestamptz,
  server_now timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;

  return query
  select
    settings.active_provider,
    case when settings.scheduled_at > now() then settings.scheduled_provider else null end,
    case when settings.scheduled_at > now() then settings.scheduled_at else null end,
    case
      when settings.scheduled_at is not null and settings.scheduled_at <= now()
        then settings.scheduled_provider
      else settings.active_provider
    end,
    settings.updated_by,
    settings.updated_at,
    now()
  from public.booking_page_settings as settings
  where settings.id = true;
end;
$$;

create or replace function public.set_booking_page_now(p_provider text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;
  if p_provider not in ('wheelbase', 'supabase') then
    raise exception 'Unknown booking provider.';
  end if;

  update public.booking_page_settings
  set active_provider = p_provider,
      scheduled_provider = null,
      scheduled_at = null,
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;
end;
$$;

create or replace function public.schedule_booking_page_switch(
  p_provider text,
  p_scheduled_at timestamptz
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_effective_provider text;
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;
  if p_provider not in ('wheelbase', 'supabase') then
    raise exception 'Unknown booking provider.';
  end if;
  if p_scheduled_at is null or p_scheduled_at <= now() then
    raise exception 'Scheduled switch must be in the future.';
  end if;

  select case
    when settings.scheduled_at is not null and settings.scheduled_at <= now()
      then settings.scheduled_provider
    else settings.active_provider
  end
  into v_effective_provider
  from public.booking_page_settings as settings
  where settings.id = true
  for update;

  if p_provider = v_effective_provider then
    raise exception 'The selected provider is already live.';
  end if;

  update public.booking_page_settings
  set active_provider = v_effective_provider,
      scheduled_provider = p_provider,
      scheduled_at = p_scheduled_at,
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;
end;
$$;

create or replace function public.cancel_booking_page_switch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_effective_provider text;
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;

  select case
    when settings.scheduled_at is not null and settings.scheduled_at <= now()
      then settings.scheduled_provider
    else settings.active_provider
  end
  into v_effective_provider
  from public.booking_page_settings as settings
  where settings.id = true
  for update;

  update public.booking_page_settings
  set active_provider = v_effective_provider,
      scheduled_provider = null,
      scheduled_at = null,
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;
end;
$$;

revoke all on function public.get_admin_booking_page_setting() from public;
revoke all on function public.set_booking_page_now(text) from public;
revoke all on function public.schedule_booking_page_switch(text, timestamptz) from public;
revoke all on function public.cancel_booking_page_switch() from public;
grant execute on function public.get_admin_booking_page_setting() to authenticated;
grant execute on function public.set_booking_page_now(text) to authenticated;
grant execute on function public.schedule_booking_page_switch(text, timestamptz) to authenticated;
grant execute on function public.cancel_booking_page_switch() to authenticated;

do $$
begin
  if to_regprocedure('public.capture_admin_audit_log()') is not null then
    execute 'drop trigger if exists rentmect_admin_audit on public.booking_page_settings';
    execute 'create trigger rentmect_admin_audit
      after insert or update or delete on public.booking_page_settings
      for each row execute function public.capture_admin_audit_log()';
  end if;
end;
$$;
