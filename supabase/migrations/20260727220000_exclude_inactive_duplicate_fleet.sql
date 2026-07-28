-- Only active physical fleet records participate in TollSpot. This excludes
-- the inactive duplicate Ford record while keeping every active real car
-- enrolled automatically.

create or replace function public.enforce_tollspot_for_real_fleet()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.tollspot_enabled :=
    new.id <> '00000000-0000-4000-8000-000000000015'::uuid
    and coalesce(new.is_active, true);
  if new.tollspot_enabled then
    new.plate_state := coalesce(nullif(upper(trim(new.plate_state)), ''), 'CT');
    new.plate_country := coalesce(nullif(upper(trim(new.plate_country)), ''), 'US');
    new.plate_assigned_at := coalesce(new.plate_assigned_at, new.created_at, now());
    new.tollspot_vehicle_type := coalesce(
      new.tollspot_vehicle_type,
      case
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%TRUCK%' then 'TRUCK'
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%VAN%' then 'SUV'
        when upper(coalesce(new.vehicle_type, '') || ' ' || coalesce(new.name, '')) like '%SUV%' then 'SUV'
        else 'SEDAN'
      end
    );
  end if;
  return new;
end;
$$;

update public.vehicles
set tollspot_enabled =
  id <> '00000000-0000-4000-8000-000000000015'::uuid
  and coalesce(is_active, true);

comment on function public.enforce_tollspot_for_real_fleet() is
  'Automatically enrolls every active real fleet vehicle in TollSpot and excludes system tests or inactive duplicate records.';
