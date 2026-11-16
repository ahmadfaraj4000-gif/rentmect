begin;
-- Patch the exact live definitions, preserving unrelated return and mileage rules.
do $migration$
declare
  definition text;
  start_at integer;
  end_at integer;
  replacement text := $notify$
  insert into public.admin_notification_events (event_type, source_id, rental_id, dedupe_key, metadata)
  select 'maintenance_due', schedule.id, null,
    'maintenance_due:' || schedule.id::text || ':' || coalesce(schedule.next_due_mileage::text, schedule.next_due_at::text, 'due'),
    jsonb_build_object('vehicle_id', p_vehicle_id, 'service_type', schedule.service_type)
  from public.vehicle_maintenance_schedules schedule
  where schedule.vehicle_id = p_vehicle_id and schedule.active
    and ((schedule.next_due_mileage is not null and v_vehicle.current_mileage is not null and v_vehicle.current_mileage >= schedule.next_due_mileage)
      or (schedule.next_due_at is not null and current_date >= schedule.next_due_at))
  on conflict (dedupe_key) do nothing;

$notify$;
begin
  if (select md5(prosrc) from pg_proc where oid='public.evaluate_vehicle_maintenance(uuid)'::regprocedure) <> '10fa50f1513db189c2a9e97cc753f98f' then
    raise exception 'Maintenance evaluator changed since the production audit';
  end if;
  definition := pg_get_functiondef('public.evaluate_vehicle_maintenance(uuid)'::regprocedure);
  start_at := strpos(definition, '  v_override_active :=');
  end_at := strpos(definition, '  select schedule.* into v_soon');
  if start_at=0 or end_at<=start_at then raise exception 'Maintenance evaluator structure changed'; end if;
  definition := substr(definition,1,start_at-1)||replacement||substr(definition,end_at);
  execute definition;

  if (select md5(prosrc) from pg_proc where oid='public.enforce_rental_odometer_gate()'::regprocedure) <> '6f236ff5c7b15ff127141a7c08636771' then
    raise exception 'Rental odometer gate changed since the production audit';
  end if;
  definition := pg_get_functiondef('public.enforce_rental_odometer_gate()'::regprocedure);
  start_at := strpos(definition, '  if v_status = ''active''');
  end_at := strpos(definition, '  if v_status = ''completed''');
  if start_at=0 or end_at<=start_at or strpos(substr(definition,start_at,end_at-start_at),'Required maintenance is due')=0 then
    raise exception 'Rental odometer gate structure changed';
  end if;
  definition := substr(definition,1,start_at-1)||substr(definition,end_at);
  execute definition;
end
$migration$;

-- Remove only the flags installed by the automatic evaluator. Restore a known
-- pre-lock status; retain an existing maintenance status if its origin is unknown.
update public.vehicles
set status = case when lower(coalesce(status,''))='maintenance'
                       and maintenance_prelock_status is not null
                       and lower(maintenance_prelock_status)<>'maintenance'
                  then maintenance_prelock_status else status end,
    maintenance_lock_active=false, maintenance_lock_reason=null,
    maintenance_lock_schedule_id=null, maintenance_locked_at=null,
    maintenance_override_until=null, maintenance_override_reason=null,
    maintenance_override_admin_id=null, maintenance_prelock_status=null
where coalesce(maintenance_lock_active,false) and maintenance_lock_schedule_id is not null;


commit;
