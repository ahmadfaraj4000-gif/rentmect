-- Cars-2 is the permanent public booking surface.
-- This locks routing only. The Wheelbase availability integration remains untouched.

alter table public.booking_page_settings
  alter column active_provider set default 'supabase';

insert into public.booking_page_settings (id, active_provider)
values (true, 'supabase')
on conflict (id) do update
set active_provider = 'supabase',
    scheduled_provider = null,
    scheduled_at = null,
    updated_at = now();

do $$
begin
  if to_regclass('public.site_promotions') is not null then
    alter table public.site_promotions
      alter column cta_url set default 'cars-2.html',
      alter column banner_pages set default array['cars-2.html']::text[];

    update public.site_promotions
    set cta_url = replace(cta_url, 'cars.html', 'cars-2.html'),
        popup_pages = array_replace(popup_pages, 'cars.html', 'cars-2.html'),
        banner_pages = array_replace(banner_pages, 'cars.html', 'cars-2.html')
    where cta_url like '%cars.html%'
       or 'cars.html' = any(popup_pages)
       or 'cars.html' = any(banner_pages);

    alter table public.site_promotions
      drop constraint if exists site_promotions_popup_pages_check,
      drop constraint if exists site_promotions_banner_pages_check;

    alter table public.site_promotions
      add constraint site_promotions_popup_pages_check
        check (popup_pages <@ array['index.html', 'cars-2.html']::text[]),
      add constraint site_promotions_banner_pages_check
        check (banner_pages <@ array['index.html', 'cars-2.html']::text[]);
  end if;
end;
$$;

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
    'supabase'::text,
    'cars-2.html'::text,
    null::text,
    null::text,
    null::timestamptz,
    now();
$$;

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
    'supabase'::text,
    null::text,
    null::timestamptz,
    'supabase'::text,
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
  if p_provider <> 'supabase' then
    raise exception 'Legacy booking pages are disabled. Cars-2 is the permanent booking page.';
  end if;

  update public.booking_page_settings
  set active_provider = 'supabase',
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
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;

  raise exception 'Booking-page switching is disabled. Cars-2 is the permanent booking page.';
end;
$$;

create or replace function public.cancel_booking_page_switch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required.';
  end if;

  update public.booking_page_settings
  set active_provider = 'supabase',
      scheduled_provider = null,
      scheduled_at = null,
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;
end;
$$;

revoke all on function public.get_public_booking_page_setting() from public;
revoke all on function public.get_admin_booking_page_setting() from public;
revoke all on function public.set_booking_page_now(text) from public;
revoke all on function public.schedule_booking_page_switch(text, timestamptz) from public;
revoke all on function public.cancel_booking_page_switch() from public;

grant execute on function public.get_public_booking_page_setting() to anon, authenticated;
grant execute on function public.get_admin_booking_page_setting() to authenticated;
grant execute on function public.set_booking_page_now(text) to authenticated;
grant execute on function public.schedule_booking_page_switch(text, timestamptz) to authenticated;
grant execute on function public.cancel_booking_page_switch() to authenticated;
