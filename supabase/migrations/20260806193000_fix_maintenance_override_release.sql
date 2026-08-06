begin;

-- Some established fleet vehicles received their odometer after the OEM
-- maintenance schedules were first installed. Those schedules retained a
-- zero-mile baseline and could immediately lock a high-mileage vehicle even
-- though the vehicle's legacy maintenance baseline was current.
update public.vehicle_maintenance_schedules schedule
set last_service_mileage = coalesce(
      vehicle.last_maintenance_mileage,
      vehicle.current_mileage,
      vehicle.original_mileage
    )
from public.vehicles vehicle
where schedule.vehicle_id = vehicle.id
  and schedule.source = 'oem_default'
  and coalesce(schedule.last_service_mileage, 0) = 0
  and coalesce(
        vehicle.last_maintenance_mileage,
        vehicle.current_mileage,
        vehicle.original_mileage,
        0
      ) > 0
  and not exists (
    select 1
    from public.vehicle_maintenance_service_logs service_log
    where service_log.schedule_id = schedule.id
  );

-- Keep the operational status consistent with a successfully recorded,
-- time-limited maintenance override.
create or replace function public.restore_vehicle_status_after_maintenance_override()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not coalesce(new.maintenance_lock_active, false)
     and new.maintenance_override_until is not null
     and new.maintenance_override_until > now()
     and lower(coalesce(new.status, '')) = 'maintenance' then
    update public.vehicles
    set status = coalesce(nullif(new.maintenance_prelock_status, 'maintenance'), 'available')
    where id = new.id
      and lower(coalesce(status, '')) = 'maintenance';
  end if;
  return new;
end;
$$;

drop trigger if exists vehicles_restore_status_after_maintenance_override
  on public.vehicles;
create trigger vehicles_restore_status_after_maintenance_override
after update of maintenance_lock_active, maintenance_override_until
on public.vehicles
for each row execute function public.restore_vehicle_status_after_maintenance_override();

-- Repair overrides that were recorded before the trigger existed.
update public.vehicles
set status = coalesce(nullif(maintenance_prelock_status, 'maintenance'), 'available')
where not coalesce(maintenance_lock_active, false)
  and maintenance_override_until is not null
  and maintenance_override_until > now()
  and lower(coalesce(status, '')) = 'maintenance';

commit;
