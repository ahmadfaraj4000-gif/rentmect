begin;

create or replace function public.enforce_completed_deposit_before_vehicle_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.status, '')) = 'active'
     and (
       tg_op = 'INSERT'
       or lower(coalesce(old.status, '')) is distinct from lower(coalesce(new.status, ''))
     )
     and not public.rentmect_rental_requirement_complete(new.id, 'deposit') then
    raise exception 'Complete the security deposit step before releasing the vehicle.';
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_require_completed_deposit_before_release on public.rentals;
create trigger rentals_require_completed_deposit_before_release
before insert or update of status on public.rentals
for each row execute function public.enforce_completed_deposit_before_vehicle_release();

commit;
