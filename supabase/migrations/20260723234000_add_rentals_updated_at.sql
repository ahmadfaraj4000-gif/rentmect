-- Restore the timestamp contract used by rental lifecycle procedures.
-- Safe to run against an existing production table.

alter table public.rentals
  add column if not exists updated_at timestamptz;

update public.rentals
set updated_at = coalesce(updated_at, created_at, now())
where updated_at is null;

alter table public.rentals
  alter column updated_at set default now(),
  alter column updated_at set not null;

create or replace function public.set_rentals_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists rentals_set_updated_at on public.rentals;
create trigger rentals_set_updated_at
before update on public.rentals
for each row
execute function public.set_rentals_updated_at();
