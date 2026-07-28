-- Gives admins an explicit customer-facing publish switch without changing
-- operational status or availability. Existing vehicles remain published.

alter table public.vehicles
  add column if not exists published boolean not null default true;

create index if not exists vehicles_published_idx
  on public.vehicles (published);

update public.vehicles
set published = true
where published is null;

-- The internal checkout-preview vehicle is reachable only through its fixed
-- preview link and should never appear in normal customer fleet lists.
update public.vehicles
set published = false
where id = '00000000-0000-4000-8000-000000000015';
