-- Mileage capture for pickup and return.
-- Run this after rental_workflow_security_hardening.sql.

alter table public.vehicles
  add column if not exists current_mileage integer
    check (current_mileage is null or current_mileage >= 0);

alter table public.rentals
  add column if not exists starting_mileage integer
    check (starting_mileage is null or starting_mileage >= 0),
  add column if not exists ending_mileage integer
    check (ending_mileage is null or ending_mileage >= 0),
  add column if not exists miles_driven integer
    generated always as (
      case
        when starting_mileage is not null and ending_mileage is not null
        then ending_mileage - starting_mileage
        else null
      end
    ) stored;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'rentals_mileage_order_check'
      and conrelid = 'public.rentals'::regclass
  ) then
    alter table public.rentals
      add constraint rentals_mileage_order_check
        check (
          starting_mileage is null
          or ending_mileage is null
          or ending_mileage >= starting_mileage
        ) not valid;
  end if;
end $$;

alter table public.rentals validate constraint rentals_mileage_order_check;

alter table public.rental_return_inspections
  add column if not exists ending_mileage integer
    check (ending_mileage is null or ending_mileage >= 0);

drop function if exists public.admin_mark_rental_active(uuid);
drop function if exists public.admin_mark_rental_active(uuid, integer);
create or replace function public.admin_mark_rental_active(
  p_rental_id uuid,
  p_starting_mileage integer,
  p_override_missing_requirements boolean default false,
  p_missing_requirements text[] default '{}'::text[]
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  if p_starting_mileage is null or p_starting_mileage < 0 then
    raise exception 'Starting mileage is required.';
  end if;

  select * into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  select * into v_vehicle
    from public.vehicles
    where id = v_rental.vehicle_id
    for update;

  if found
     and v_vehicle.current_mileage is not null
     and p_starting_mileage < v_vehicle.current_mileage then
    raise exception 'Starting mileage cannot be below the vehicle current mileage.';
  end if;

  if p_override_missing_requirements then
    raise exception 'Procedure overrides are disabled. Complete every verification, document, agreement, and payment step.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('document_review', 'approved', 'ready_for_pickup') then
    raise exception 'Only reviewed rentals can be marked active.';
  end if;

  if not coalesce(v_rental.agreement_signed, false)
     or lower(coalesce(v_rental.payment_status, '')) <> 'paid') then
    raise exception 'Signed agreement and paid rental are required.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_rental.user_id and coalesce(p.phone_verified, false)
  ) or not public.rentmect_identity_is_verified(v_rental.user_id) then
    raise exception 'Verified phone and identity are required before vehicle release.';
  end if;

  if (
    not exists (
    select 1 from (
      select status from public.rental_documents
      where user_id = v_rental.user_id and document_type = 'license'
      order by created_at desc nulls last limit 1
    ) license where lower(coalesce(license.status, '')) = 'approved'
  ) or not exists (
    select 1 from (
      select status from public.rental_documents
      where rental_id = v_rental.id and user_id = v_rental.user_id and document_type = 'insurance'
      order by created_at desc nulls last limit 1
    ) insurance where lower(coalesce(insurance.status, '')) = 'approved'
  )) then
    raise exception 'Approved driver license and insurance documents are required before release.';
  end if;

  update public.rentals
    set status = 'active',
        starting_mileage = p_starting_mileage,
        ending_mileage = null
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = 'rented',
        current_mileage = p_starting_mileage
    where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_rental_marked_active',
    jsonb_build_object(
      'starting_mileage', p_starting_mileage,
      'override_missing_requirements', p_override_missing_requirements,
      'missing_requirements', to_jsonb(p_missing_requirements)
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.admin_mark_rental_active(uuid, integer, boolean, text[]) from public;
grant execute on function public.admin_mark_rental_active(uuid, integer, boolean, text[]) to authenticated;

create or replace function public.admin_override_rental_ready_for_pickup(
  p_rental_id uuid,
  p_missing_requirements text[] default '{}'::text[]
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  select * into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup') then
    raise exception 'Only pending or reviewed rentals can be override marked ready for pickup.';
  end if;

  if v_rental.vehicle_id is null or v_rental.pickup_date is null or v_rental.return_date is null then
    raise exception 'Vehicle and rental dates are required before pickup override.';
  end if;

  update public.rentals
    set status = 'ready_for_pickup'
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and coalesce(lower(status), 'available') not in ('maintenance', 'unavailable', 'inactive', 'rented');

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_rental_ready_for_pickup_override',
    jsonb_build_object('missing_requirements', to_jsonb(p_missing_requirements))
  );

  return v_rental;
end;
$$;

revoke all on function public.admin_override_rental_ready_for_pickup(uuid, text[]) from public;

drop function if exists public.admin_complete_rental_return(uuid);
create or replace function public.admin_complete_rental_return(
  p_rental_id uuid,
  p_ending_mileage integer
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  if p_ending_mileage is null or p_ending_mileage < 0 then
    raise exception 'Ending mileage is required.';
  end if;

  select * into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue', 'return_initiated') then
    raise exception 'Only out or returned rentals can be completed.';
  end if;

  if v_rental.starting_mileage is not null
     and p_ending_mileage < v_rental.starting_mileage then
    raise exception 'Ending mileage cannot be below starting mileage.';
  end if;

  update public.rentals
    set status = 'completed',
        ending_mileage = p_ending_mileage
    where id = v_rental.id
    returning * into v_rental;

  update public.vehicles
    set status = 'available',
        current_mileage = p_ending_mileage
    where id = v_rental.vehicle_id
      and lower(coalesce(status, '')) = 'rented';

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_rental_completed',
    jsonb_build_object(
      'starting_mileage', v_rental.starting_mileage,
      'ending_mileage', p_ending_mileage,
      'miles_driven', v_rental.miles_driven
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.admin_complete_rental_return(uuid, integer) from public;
grant execute on function public.admin_complete_rental_return(uuid, integer) to authenticated;
