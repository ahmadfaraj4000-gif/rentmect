-- Remove the inactive duplicate Ford fleet record from the shared portal data.
-- This is intentionally database-only and does not call or modify Wheelbase.

-- Cascading maintenance-schedule deletion runs after the parent vehicle is
-- already gone. Treat that normal cascade as a no-op instead of raising
-- "Vehicle not found."
create or replace function public.evaluate_vehicle_maintenance_after_schedule()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vehicle_id uuid := case when tg_op = 'DELETE' then old.vehicle_id else new.vehicle_id end;
begin
  if exists (select 1 from public.vehicles where id = v_vehicle_id) then
    perform public.evaluate_vehicle_maintenance(v_vehicle_id);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

do $$
declare
  v_duplicate public.vehicles%rowtype;
begin
  select *
  into v_duplicate
  from public.vehicles
  where id = 'eeec87e0-f7a7-4715-8b70-a1f509b3e75b'::uuid
  for update;

  if not found then
    raise exception 'Expected duplicate Ford vehicle was not found.';
  end if;
  if v_duplicate.name <> 'Ford F350 4x4 #191'
     or v_duplicate.is_active is distinct from false
     or v_duplicate.vin is not null
     or v_duplicate.plate_number is not null then
    raise exception 'Duplicate Ford safety check failed; refusing deletion.';
  end if;
  if exists (
    select 1
    from public.rentals
    where vehicle_id = v_duplicate.id
  ) then
    raise exception 'Duplicate Ford has rental references; refusing deletion.';
  end if;

  delete from public.vehicles
  where id = v_duplicate.id;
end
$$;

-- August 1 at midnight in New York is 04:00 UTC while daylight saving time
-- is active. Anything incurred before then remains audit-only.
do $$
declare
  v_cutoff constant timestamptz := '2026-08-01T04:00:00Z'::timestamptz;
begin
  if exists (
    select 1
    from public.tollspot_transactions
    where occurred_at < v_cutoff
      and (
        status in ('charge_created', 'paid')
        or rental_charge_item_id is not null
      )
  ) then
    raise exception 'A pre-cutoff TollSpot customer charge exists; refusing cutoff change.';
  end if;

  update public.billing_automation_settings
  set tollspot_charge_start_at = v_cutoff,
      updated_at = now()
  where id = true;

  update public.tollspot_transactions
  set status = 'ignored',
      rental_id = null,
      rental_charge_item_id = null,
      ignored_reason = 'Transaction predates TollSpot customer-charge activation.',
      review_reason = null,
      updated_at = now()
  where occurred_at < v_cutoff
    and status not in ('charge_created', 'paid');
end
$$;
