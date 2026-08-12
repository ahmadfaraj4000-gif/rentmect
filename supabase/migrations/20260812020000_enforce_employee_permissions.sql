begin;

-- Employee permissions must be enforced by Postgres as well as by the portal.
-- Owners, Operations Managers, customers, and service-role automation retain
-- their existing behavior; these guards apply only to staff_role = employee.
create or replace function public.rentmect_enforce_employee_table_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff_role text;
  v_permission text;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select staff_role into v_staff_role from public.profiles where id = auth.uid();
  if v_staff_role is distinct from 'employee' then return coalesce(new, old); end if;

  foreach v_permission in array tg_argv loop
    if coalesce(public.rentmect_has_permission(v_permission), false) then
      return coalesce(new, old);
    end if;
  end loop;

  raise exception 'Your Employee role does not have permission for this action.';
end;
$$;

create or replace function public.rentmect_employee_permission_allows(p_permission_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when profile.staff_role = 'employee'
        then coalesce(public.rentmect_has_permission(p_permission_key), false)
      else true
    end
    from public.profiles profile
    where profile.id = auth.uid()
  ), true);
$$;

do $$
declare
  v_table text;
  v_permission text;
  v_trigger text;
begin
  for v_table, v_permission in
    select * from (values
      ('profiles', 'customer.manage'),
      ('rental_documents', 'rental.edit'),
      ('rental_messages', 'communications.send'),
      ('admin_customer_messages', 'communications.send'),
      ('email_templates', 'communications.templates'),
      ('sms_templates', 'communications.templates'),
      ('rental_charge_items', 'charge.manage'),
      ('rental_payments', 'payment.collect'),
      ('rental_payment_refunds', 'payment.refund'),
      ('rental_deposit_allocations', 'deposit.resolve'),
      ('rental_emergency_exceptions', 'override.emergency'),
      ('vehicle_availability_blocks', 'vehicle.manage'),
      ('vehicle_maintenance_schedules', 'vehicle.manage'),
      ('vehicle_maintenance_service_logs', 'vehicle.manage'),
      ('discount_codes', 'settings.operational'),
      ('service_fees', 'settings.operational'),
      ('site_promotions', 'settings.operational'),
      ('under_25_pricing_settings', 'settings.operational'),
      ('billing_automation_settings', 'settings.operational'),
      ('booking_policy_settings', 'settings.operational'),
      ('admin_booking_settings', 'settings.operational')
    ) permissions(table_name, permission_key)
  loop
    if to_regclass(format('public.%I', v_table)) is null then continue; end if;
    v_trigger := 'enforce_employee_permission_' || v_table;
    execute format('drop trigger if exists %I on public.%I', v_trigger, v_table);
    execute format(
      'create trigger %I before insert or update or delete on public.%I for each row execute function public.rentmect_enforce_employee_table_permission(%L)',
      v_trigger, v_table, v_permission
    );
  end loop;
end;
$$;

-- Rental mutations need column-aware checks because payment automation also
-- updates the rental row. Only the business action that changed is evaluated.
create or replace function public.rentmect_enforce_employee_rental_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff_role text;
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_key text;
  v_changed boolean;
begin
  if auth.uid() is null then return new; end if;
  select staff_role into v_staff_role from public.profiles where id = auth.uid();
  if v_staff_role is distinct from 'employee' then return new; end if;

  if (v_new ->> 'status') is distinct from (v_old ->> 'status') then
    if lower(coalesce(v_new ->> 'status', '')) in ('cancelled', 'canceled') then
      if not coalesce(public.rentmect_has_permission('rental.cancel'), false) then
        raise exception 'Rental cancellation permission is required.';
      end if;
    elsif lower(coalesce(v_new ->> 'status', '')) = 'completed' then
      if not coalesce(public.rentmect_has_permission('rental.return'), false) then
        raise exception 'Rental return permission is required.';
      end if;
    elsif not (
      coalesce(public.rentmect_has_permission('rental.edit'), false)
      or coalesce(public.rentmect_has_permission('override.emergency'), false)
    ) then
      raise exception 'Rental editing permission is required.';
    end if;
  end if;

  v_changed := false;
  foreach v_key in array array[
    'manual_discount_type', 'manual_discount_value', 'manual_discount_amount',
    'manual_discount_reason', 'manual_discount_tax_savings',
    'pre_manual_discount_rental_total'
  ] loop
    v_changed := v_changed or (v_new -> v_key) is distinct from (v_old -> v_key);
  end loop;
  if v_changed and not coalesce(public.rentmect_has_permission('rental.discount'), false) then
    raise exception 'Rental discount permission is required.';
  end if;

  v_changed := false;
  foreach v_key in array array[
    'vehicle_id', 'pickup_date', 'pickup_time', 'return_date', 'return_time',
    'daily_rate', 'base_rental_total', 'rental_total', 'security_deposit'
  ] loop
    v_changed := v_changed or (v_new -> v_key) is distinct from (v_old -> v_key);
  end loop;
  if v_changed and not coalesce(public.rentmect_has_permission('rental.edit'), false) then
    raise exception 'Rental editing permission is required.';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_employee_rental_permission on public.rentals;
create trigger enforce_employee_rental_permission
before update on public.rentals
for each row execute function public.rentmect_enforce_employee_rental_permission();

create or replace function public.rentmect_enforce_employee_vehicle_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff_role text;
  v_old jsonb := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  v_new jsonb := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
  v_non_lifecycle_old jsonb;
  v_non_lifecycle_new jsonb;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select staff_role into v_staff_role from public.profiles where id = auth.uid();
  if v_staff_role is distinct from 'employee' then return coalesce(new, old); end if;

  if tg_op in ('INSERT', 'DELETE') then
    if not coalesce(public.rentmect_has_permission('vehicle.manage'), false) then
      raise exception 'Vehicle management permission is required.';
    end if;
    return coalesce(new, old);
  end if;

  v_non_lifecycle_old := v_old - array['status', 'current_mileage', 'updated_at'];
  v_non_lifecycle_new := v_new - array['status', 'current_mileage', 'updated_at'];
  if v_non_lifecycle_new is distinct from v_non_lifecycle_old
     and not coalesce(public.rentmect_has_permission('vehicle.manage'), false) then
    raise exception 'Vehicle management permission is required.';
  end if;

  if ((v_new -> 'status') is distinct from (v_old -> 'status')
      or (v_new -> 'current_mileage') is distinct from (v_old -> 'current_mileage'))
     and not (
       coalesce(public.rentmect_has_permission('vehicle.manage'), false)
       or coalesce(public.rentmect_has_permission('rental.return'), false)
       or coalesce(public.rentmect_has_permission('rental.edit'), false)
       or coalesce(public.rentmect_has_permission('override.emergency'), false)
     ) then
    raise exception 'A vehicle, rental editing, return, or emergency permission is required.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_employee_vehicle_permission on public.vehicles;
create trigger enforce_employee_vehicle_permission
before insert or update or delete on public.vehicles
for each row execute function public.rentmect_enforce_employee_vehicle_permission();

-- Close the legacy external-deposit route that previously checked only the
-- broad admin role. The queue wrapper and the older rental-card action now
-- share the same database permission boundary.
create or replace function public.admin_record_local_deposit_release(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_released numeric := 0;
  v_remaining numeric := 0;
  v_blockers jsonb := '[]'::jsonb;
begin
  if coalesce(public.rentmect_has_permission('deposit.resolve'), false) is not true then
    raise exception 'Deposit resolution permission is required.';
  end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) <> 'completed' then
    raise exception 'The deposit can be returned only after the rental is completed.';
  end if;

  v_blockers := public.rentmect_deposit_chain_release_blockers(v_rental.id);
  if jsonb_array_length(v_blockers) > 0 then
    raise exception 'Deposit release is blocked by the continuation chain: %', v_blockers::text;
  end if;

  perform public.ensure_rental_deposit_allocation(v_rental.id);
  select coalesce(sum(amount_held - amount_released), 0) into v_released
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');
  if v_released <= 0 then raise exception 'No externally held deposit allocation remains.'; end if;

  update public.rental_deposit_allocations
  set amount_released = amount_held, status = 'released', last_error = null, updated_at = now()
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');

  select coalesce(sum(amount_held - amount_released), 0) into v_remaining
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id and status <> 'released';

  update public.rentals
  set deposit_held_amount = v_remaining,
      deposit_released_amount = coalesce(deposit_released_amount, 0) + v_released,
      deposit_status = case when v_remaining <= 0 then 'released' else deposit_status end,
      deposit_released_at = case when v_remaining <= 0 then now() else deposit_released_at end,
      deposit_release_reason = 'External deposit return recorded after continuation-chain validation.',
      deposit_decrease_refund_due = case when v_remaining <= 0 then 0 else deposit_decrease_refund_due end,
      updated_at = now()
  where id = v_rental.id returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_local_deposit_release_recorded',
    jsonb_build_object('amount', v_released, 'continuation_chain_checked', true));
  return v_rental;
end;
$$;

revoke all on function public.admin_record_local_deposit_release(uuid) from public;
grant execute on function public.admin_record_local_deposit_release(uuid) to authenticated;

-- Sensitive reads stay server-enforced even if an Employee tries to bypass a
-- hidden tab with a direct REST query.
do $$
declare v_table text;
begin
  foreach v_table in array array['admin_audit_logs'] loop
    if to_regclass(format('public.%I', v_table)) is null then continue; end if;
    execute format('alter table public.%I enable row level security', v_table);
    execute format('drop policy if exists "Employee permission guard" on public.%I', v_table);
    execute format(
      'create policy "Employee permission guard" on public.%I as restrictive for select to authenticated using (public.rentmect_employee_permission_allows(''audit.view''))',
      v_table
    );
  end loop;

  foreach v_table in array array[
    'rental_payments', 'rental_payment_refunds', 'stripe_reconciliation_issues',
    'rental_deposit_allocations'
  ] loop
    if to_regclass(format('public.%I', v_table)) is null then continue; end if;
    execute format('alter table public.%I enable row level security', v_table);
    execute format('drop policy if exists "Employee financial visibility guard" on public.%I', v_table);
    execute format(
      'create policy "Employee financial visibility guard" on public.%I as restrictive for select to authenticated using (public.rentmect_employee_permission_allows(''reports.financial''))',
      v_table
    );
  end loop;
end;
$$;

commit;
