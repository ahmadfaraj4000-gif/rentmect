-- Admin-managed promotional popups and banners for the public website.
-- Run this migration in the Supabase SQL editor before using Promotion Manager.

create table if not exists public.site_promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  coupon_code text not null,
  badge_text text not null default 'SPECIAL OFFER',
  offer_value text not null default '15%',
  offer_suffix text not null default 'off',
  popup_kicker text not null default 'Limited-Time Special',
  popup_title text not null,
  popup_body text not null,
  banner_title text not null,
  banner_body text not null default 'Use code',
  cta_label text not null default 'Choose Your Car',
  cta_url text not null default 'cars-2.html',
  fine_print text,
  starts_at timestamptz,
  ends_at timestamptz not null,
  popup_enabled boolean not null default true,
  banner_enabled boolean not null default true,
  popup_pages text[] not null default array['index.html']::text[],
  banner_pages text[] not null default array['cars-2.html']::text[],
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (char_length(trim(name)) between 1 and 80),
  check (char_length(trim(coupon_code)) between 2 and 32),
  check (char_length(badge_text) <= 32),
  check (char_length(offer_value) <= 20),
  check (char_length(offer_suffix) <= 20),
  check (char_length(popup_kicker) <= 60),
  check (char_length(popup_title) between 1 and 120),
  check (char_length(popup_body) between 1 and 280),
  check (char_length(banner_title) between 1 and 120),
  check (char_length(banner_body) <= 120),
  check (char_length(cta_label) between 1 and 60),
  check (char_length(cta_url) between 1 and 300),
  check (fine_print is null or char_length(fine_print) <= 300),
  check (starts_at is null or ends_at > starts_at),
  check (popup_pages <@ array['index.html', 'cars-2.html']::text[]),
  check (banner_pages <@ array['index.html', 'cars-2.html']::text[]),
  check (not popup_enabled or cardinality(popup_pages) > 0),
  check (not banner_enabled or cardinality(banner_pages) > 0),
  check (popup_enabled or banner_enabled)
);

create index if not exists site_promotions_public_lookup_idx
  on public.site_promotions (active, ends_at desc, updated_at desc);

create or replace function public.set_site_promotions_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists set_site_promotions_updated_at on public.site_promotions;
create trigger set_site_promotions_updated_at
before update on public.site_promotions
for each row execute function public.set_site_promotions_updated_at();

alter table public.site_promotions enable row level security;

drop policy if exists "Visitors can read current site promotions" on public.site_promotions;
create policy "Visitors can read current site promotions"
on public.site_promotions
for select
to anon
using (
  active = true
  and (starts_at is null or starts_at <= now())
  and ends_at > now()
);

drop policy if exists "Admins can read site promotions" on public.site_promotions;
create policy "Admins can read site promotions"
on public.site_promotions
for select
to authenticated
using (public.is_admin());

drop policy if exists "Admins can create site promotions" on public.site_promotions;
create policy "Admins can create site promotions"
on public.site_promotions
for insert
to authenticated
with check (public.is_admin());

drop policy if exists "Admins can update site promotions" on public.site_promotions;
create policy "Admins can update site promotions"
on public.site_promotions
for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins can delete site promotions" on public.site_promotions;
create policy "Admins can delete site promotions"
on public.site_promotions
for delete
to authenticated
using (public.is_admin());

grant select on public.site_promotions to anon;
grant select, insert, update, delete on public.site_promotions to authenticated;

-- Preserve the currently scheduled promotion as the first editable campaign.
insert into public.site_promotions (
  name,
  coupon_code,
  badge_text,
  offer_value,
  offer_suffix,
  popup_kicker,
  popup_title,
  popup_body,
  banner_title,
  banner_body,
  cta_label,
  cta_url,
  fine_print,
  starts_at,
  ends_at,
  popup_enabled,
  banner_enabled,
  popup_pages,
  banner_pages,
  active
)
select
  'Weekend Special — July 2026',
  'WEEKEND071726',
  '15% OFF',
  '15%',
  'off',
  'Weekend Special',
  'Your weekend ride just got better.',
  'Book before midnight Monday and use this discount code at checkout.',
  'Weekend special ends Monday at midnight',
  'Use code',
  'Choose Your Car',
  'cars-2.html',
  'Ends at 12:00 AM Tuesday, July 21, 2026 (Eastern)—the end of Monday night. Terms may apply.',
  '2026-07-17 00:00:00-04',
  '2026-07-21 00:00:00-04',
  true,
  true,
  array['index.html']::text[],
  array['cars-2.html']::text[],
  true
where not exists (
  select 1 from public.site_promotions where coupon_code = 'WEEKEND071726'
);
