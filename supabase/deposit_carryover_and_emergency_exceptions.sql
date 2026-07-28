-- Deposit carryover ledger and controlled emergency rental-release exceptions.
-- Run after stripe_identity_verification.sql, local_payment_and_extensions.sql,
-- stripe_payments.sql, admin_audit_and_deposit_controls.sql, and
-- admin_pushover_notifications.sql.

create extension if not exists pgcrypto;

alter table public.profiles
  add column if not exists emergency_override_authorized boolean not null default false;

-- Bootstrap only the oldest existing admin as the presumed owner. Every other
-- present or future staff account remains unauthorized until explicitly enabled.
update public.profiles
set emergency_override_authorized = true
where id = (
  select id from public.profiles
  where role = 'admin'
  order by created_at nulls last, id
  limit 1
)
and emergency_override_authorized = false;

alter table public.rental_extension_requests
  add column if not exists existing_deposit_held numeric not null default 0,
  add column if not exists replacement_deposit_required numeric not null default 0,
  add column if not exists deposit_carried_amount numeric not null default 0,
  add column if not exists deposit_increase_amount numeric not null default 0,
  add column if not exists deposit_decrease_amount numeric not null default 0;

alter table public.rentals
  add column if not exists deposit_source_rental_id uuid references public.rentals(id) on delete set null,
  add column if not exists deposit_transferred_to_rental_id uuid references public.rentals(id) on delete set null,
  add column if not exists deposit_carried_amount numeric not null default 0,
  add column if not exists deposit_increase_amount numeric not null default 0,
  add column if not exists deposit_decrease_refund_due numeric not null default 0;

create table if not exists public.rental_deposit_allocations (
  id uuid primary key default gen_random_uuid(),
  holder_rental_id uuid not null references public.rentals(id) on delete cascade,
  source_rental_id uuid not null references public.rentals(id) on delete cascade,
  source_kind text not null default 'initial_rental'
    check (source_kind in ('initial_rental', 'switch_increase', 'local_payment')),
  payment_provider text not null default 'stripe'
    check (payment_provider in ('stripe', 'local')),
  stripe_payment_intent_id text,
  amount_held numeric not null check (amount_held >= 0),
  amount_released numeric not null default 0 check (amount_released >= 0),
  status text not null default 'held'
    check (status in ('held', 'refund_due_inspection', 'release_pending', 'released', 'failed')),
  refund_id text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists rental_deposit_allocations_holder_idx
  on public.rental_deposit_allocations (holder_rental_id, status);

alter table public.rental_deposit_allocations enable row level security;
drop policy if exists "Admins can read deposit allocations" on public.rental_deposit_allocations;
create policy "Admins can read deposit allocations"
  on public.rental_deposit_allocations for select to authenticated
  using (public.is_admin());
drop policy if exists "Customers can read their deposit allocations" on public.rental_deposit_allocations;
revoke insert, update, delete on public.rental_deposit_allocations from anon, authenticated;

create or replace function public.ensure_rental_deposit_allocation(
  p_rental_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_amount numeric;
begin
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if exists (
    select 1 from public.rental_deposit_allocations
    where holder_rental_id = p_rental_id
      and status in ('held', 'refund_due_inspection', 'release_pending')
  ) then return; end if;

  v_amount := greatest(coalesce(v_rental.deposit_held_amount, 0), 0);
  if v_amount <= 0 or lower(coalesce(v_rental.deposit_status, '')) <> 'held' then return; end if;

  insert into public.rental_deposit_allocations (
    holder_rental_id, source_rental_id, source_kind, payment_provider,
    stripe_payment_intent_id, amount_held
  ) values (
    v_rental.id,
    v_rental.id,
    case when lower(coalesce(v_rental.payment_provider, 'local')) = 'stripe'
      then 'initial_rental' else 'local_payment' end,
    case when lower(coalesce(v_rental.payment_provider, 'local')) = 'stripe'
      then 'stripe' else 'local' end,
    v_rental.stripe_payment_intent_id,
    v_amount
  );
end;
$$;

create or replace function public.transfer_rental_deposit_allocations(
  p_parent_rental_id uuid,
  p_replacement_rental_id uuid,
  p_required_deposit numeric,
  p_increase_provider text default 'local',
  p_increase_payment_intent_id text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_parent public.rentals%rowtype;
  v_replacement public.rentals%rowtype;
  v_allocation public.rental_deposit_allocations%rowtype;
  v_existing numeric := 0;
  v_required numeric := greatest(coalesce(p_required_deposit, 0), 0);
  v_to_carry numeric := 0;
  v_piece numeric;
  v_increase numeric := 0;
  v_decrease numeric := 0;
begin
  select * into v_parent from public.rentals where id = p_parent_rental_id for update;
  if not found then raise exception 'Parent rental not found.'; end if;
  select * into v_replacement from public.rentals where id = p_replacement_rental_id for update;
  if not found then raise exception 'Replacement rental not found.'; end if;

  perform public.ensure_rental_deposit_allocation(v_parent.id);
  select coalesce(sum(amount_held - amount_released), 0)
    into v_existing
    from public.rental_deposit_allocations
    where holder_rental_id = v_parent.id
      and status in ('held', 'refund_due_inspection');

  v_to_carry := least(v_existing, v_required);
  v_increase := greatest(v_required - v_existing, 0);
  v_decrease := greatest(v_existing - v_required, 0);

  for v_allocation in
    select * from public.rental_deposit_allocations
    where holder_rental_id = v_parent.id
      and status in ('held', 'refund_due_inspection')
      and amount_held > amount_released
    order by created_at, id
    for update
  loop
    exit when v_to_carry <= 0;
    v_piece := least(v_allocation.amount_held - v_allocation.amount_released, v_to_carry);

    if v_piece = v_allocation.amount_held - v_allocation.amount_released
       and v_allocation.amount_released = 0 then
      update public.rental_deposit_allocations
      set holder_rental_id = v_replacement.id,
          status = 'held',
          updated_at = now()
      where id = v_allocation.id;
    else
      update public.rental_deposit_allocations
      set amount_held = amount_held - v_piece,
          status = 'refund_due_inspection',
          updated_at = now()
      where id = v_allocation.id;

      insert into public.rental_deposit_allocations (
        holder_rental_id, source_rental_id, source_kind, payment_provider,
        stripe_payment_intent_id, amount_held, status
      ) values (
        v_replacement.id, v_allocation.source_rental_id, v_allocation.source_kind,
        v_allocation.payment_provider, v_allocation.stripe_payment_intent_id,
        v_piece, 'held'
      );
    end if;
    v_to_carry := v_to_carry - v_piece;
  end loop;

  if v_increase > 0 then
    insert into public.rental_deposit_allocations (
      holder_rental_id, source_rental_id, source_kind, payment_provider,
      stripe_payment_intent_id, amount_held, status
    ) values (
      v_replacement.id,
      v_replacement.id,
      case when lower(coalesce(p_increase_provider, 'local')) = 'stripe'
        then 'switch_increase' else 'local_payment' end,
      case when lower(coalesce(p_increase_provider, 'local')) = 'stripe'
        then 'stripe' else 'local' end,
      p_increase_payment_intent_id,
      v_increase,
      'held'
    );
  end if;

  if v_decrease > 0 then
    update public.rental_deposit_allocations
    set status = 'refund_due_inspection', updated_at = now()
    where holder_rental_id = v_parent.id and status = 'held';
  end if;

  update public.rentals
  set deposit_held_amount = v_decrease,
      deposit_status = case when v_decrease > 0 then 'adjustment_refund_due' else 'transferred' end,
      deposit_transferred_to_rental_id = v_replacement.id,
      deposit_decrease_refund_due = v_decrease,
      updated_at = now()
  where id = v_parent.id;

  update public.rentals
  set security_deposit = v_required,
      deposit_held_amount = v_required,
      deposit_status = case when v_required > 0 then 'held' else 'released' end,
      deposit_source_rental_id = v_parent.id,
      deposit_carried_amount = least(v_existing, v_required),
      deposit_increase_amount = v_increase,
      updated_at = now()
  where id = v_replacement.id;
end;
$$;

revoke all on function public.ensure_rental_deposit_allocation(uuid) from public;
revoke all on function public.transfer_rental_deposit_allocations(uuid, uuid, numeric, text, text) from public;
grant execute on function public.ensure_rental_deposit_allocation(uuid) to service_role;
grant execute on function public.transfer_rental_deposit_allocations(uuid, uuid, numeric, text, text) to service_role;

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
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) <> 'completed' then
    raise exception 'The deposit can be returned only after the rental is completed.';
  end if;
  perform public.ensure_rental_deposit_allocation(v_rental.id);

  select coalesce(sum(amount_held - amount_released), 0) into v_released
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');
  if v_released <= 0 then raise exception 'No externally held deposit allocation remains.'; end if;

  update public.rental_deposit_allocations
  set amount_released = amount_held,
      status = 'released',
      last_error = null,
      updated_at = now()
  where holder_rental_id = v_rental.id
    and payment_provider = 'local'
    and status in ('held', 'refund_due_inspection', 'failed');

  select coalesce(sum(amount_held - amount_released), 0) into v_remaining
  from public.rental_deposit_allocations
  where holder_rental_id = v_rental.id
    and status <> 'released';

  update public.rentals
  set deposit_held_amount = v_remaining,
      deposit_released_amount = coalesce(deposit_released_amount, 0) + v_released,
      deposit_status = case when v_remaining <= 0 then 'released' else deposit_status end,
      deposit_released_at = case when v_remaining <= 0 then now() else deposit_released_at end,
      deposit_release_reason = 'External deposit return recorded by authorized admin.',
      deposit_decrease_refund_due = case when v_remaining <= 0 then 0 else deposit_decrease_refund_due end,
      updated_at = now()
  where id = v_rental.id
  returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_local_deposit_release_recorded',
    jsonb_build_object('amount', v_released)
  );
  return v_rental;
end;
$$;
revoke all on function public.admin_record_local_deposit_release(uuid) from public;
grant execute on function public.admin_record_local_deposit_release(uuid) to authenticated;

create table if not exists public.rental_emergency_exceptions (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete restrict,
  exception_scopes text[] not null,
  resolved_scopes text[] not null default '{}',
  reason text not null,
  evidence_note text,
  status text not null default 'active'
    check (status in ('active', 'resolved', 'revoked')),
  expires_at timestamptz not null,
  starting_mileage integer,
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cardinality(exception_scopes) > 0),
  check (exception_scopes <@ array['phone','identity','license','insurance','agreement','payment']::text[])
);

create unique index if not exists rental_emergency_exception_one_active_idx
  on public.rental_emergency_exceptions (rental_id)
  where status = 'active';

alter table public.rental_emergency_exceptions enable row level security;
drop policy if exists "Admins can read emergency exceptions" on public.rental_emergency_exceptions;
create policy "Admins can read emergency exceptions"
  on public.rental_emergency_exceptions for select to authenticated
  using (public.is_admin());
drop policy if exists "Customers can read their emergency exceptions" on public.rental_emergency_exceptions;
revoke insert, update, delete on public.rental_emergency_exceptions from anon, authenticated;

create or replace function public.get_my_rental_emergency_exceptions()
returns table (
  id uuid,
  rental_id uuid,
  exception_scopes text[],
  resolved_scopes text[],
  status text,
  expires_at timestamptz,
  created_at timestamptz
)
language sql
security definer
stable
set search_path = public
as $$
  select e.id, e.rental_id, e.exception_scopes, e.resolved_scopes,
         e.status, e.expires_at, e.created_at
  from public.rental_emergency_exceptions e
  where e.user_id = auth.uid()
  order by e.created_at desc;
$$;
revoke all on function public.get_my_rental_emergency_exceptions() from public;
grant execute on function public.get_my_rental_emergency_exceptions() to authenticated;

create or replace function public.rentmect_rental_requirement_complete(
  p_rental_id uuid,
  p_scope text
) returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_rental public.rentals%rowtype;
begin
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then return false; end if;
  case p_scope
    when 'phone' then
      return exists (select 1 from public.profiles where id = v_rental.user_id and coalesce(phone_verified, false));
    when 'identity' then return public.rentmect_identity_is_verified(v_rental.user_id);
    when 'agreement' then return coalesce(v_rental.agreement_signed, false);
    when 'payment' then return lower(coalesce(v_rental.payment_status, '')) = 'paid';
    when 'license' then
      return exists (
        select 1 from public.rental_documents
        where user_id = v_rental.user_id and document_type = 'license'
          and lower(coalesce(status, '')) = 'approved'
      );
    when 'insurance' then
      return exists (
        select 1 from public.rental_documents
        where rental_id = v_rental.id and user_id = v_rental.user_id
          and document_type = 'insurance'
          and lower(coalesce(status, '')) = 'approved'
      );
    else return false;
  end case;
end;
$$;

create or replace function public.rentmect_active_exception_covers(
  p_rental_id uuid,
  p_scope text
) returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.rental_emergency_exceptions e
    where e.rental_id = p_rental_id
      and e.status = 'active'
      and e.expires_at > now()
      and p_scope = any(e.exception_scopes)
      and not (p_scope = any(e.resolved_scopes))
  );
$$;

create or replace function public.admin_activate_rental_with_emergency_exception(
  p_rental_id uuid,
  p_exception_scopes text[],
  p_reason text,
  p_evidence_note text,
  p_expires_at timestamptz,
  p_starting_mileage integer,
  p_confirmation text
) returns public.rental_emergency_exceptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_admin public.profiles%rowtype;
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_exception public.rental_emergency_exceptions%rowtype;
  v_missing text[];
  v_scope text;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_admin from public.profiles where id = v_admin_id;
  if not coalesce(v_admin.emergency_override_authorized, false) then
    raise exception 'This staff account is not authorized for emergency release exceptions.';
  end if;
  if trim(coalesce(p_confirmation, '')) <> 'RELEASE WITH EXCEPTION' then
    raise exception 'Type RELEASE WITH EXCEPTION to confirm.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 20 then
    raise exception 'Enter a specific emergency reason of at least 20 characters.';
  end if;
  if p_starting_mileage is null or p_starting_mileage < 0 then
    raise exception 'Starting mileage is required.';
  end if;
  if p_expires_at is null or p_expires_at <= now() + interval '15 minutes'
     or p_expires_at > now() + interval '24 hours' then
    raise exception 'Exception expiry must be between 15 minutes and 24 hours from now.';
  end if;
  if p_exception_scopes is null or cardinality(p_exception_scopes) = 0
     or not (p_exception_scopes <@ array['phone','identity','license','insurance','agreement','payment']::text[]) then
    raise exception 'Choose only valid incomplete procedure scopes.';
  end if;

  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) not in ('pending','documents_needed','document_review','approved','ready_for_pickup') then
    raise exception 'This rental is not eligible for emergency release.';
  end if;
  select * into v_vehicle from public.vehicles where id = v_rental.vehicle_id for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if lower(coalesce(v_vehicle.status, 'available')) in ('maintenance','unavailable','inactive','rented') then
    raise exception 'Unsafe, unavailable, inactive, or already-rented vehicles cannot be overridden.';
  end if;
  if v_vehicle.current_mileage is not null and p_starting_mileage < v_vehicle.current_mileage then
    raise exception 'Starting mileage cannot be below the vehicle current mileage.';
  end if;
  if exists (
    select 1 from public.rentals r
    where r.id <> v_rental.id
      and r.vehicle_id = v_rental.vehicle_id
      and lower(coalesce(r.status, '')) <> 'cancelled'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1 from public.vehicle_availability_blocks b
    where b.vehicle_id = v_rental.vehicle_id
      and coalesce(b.active, true)
      and lower(coalesce(b.block_type, 'unavailable')) <> 'available'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'Vehicle schedule conflicts and calendar blocks cannot be overridden.';
  end if;

  select coalesce(array_agg(scope order by scope), '{}') into v_missing
  from unnest(array['phone','identity','license','insurance','agreement','payment']::text[]) scope
  where not public.rentmect_rental_requirement_complete(v_rental.id, scope);

  if cardinality(v_missing) = 0 then raise exception 'No emergency exception is needed; all procedures are complete.'; end if;
  if not (v_missing <@ p_exception_scopes) then
    raise exception 'Every incomplete procedure must be explicitly selected: %', array_to_string(v_missing, ', ');
  end if;
  foreach v_scope in array p_exception_scopes loop
    if public.rentmect_rental_requirement_complete(v_rental.id, v_scope) then
      raise exception '% is already complete and cannot be listed as an exception.', initcap(v_scope);
    end if;
  end loop;

  insert into public.rental_emergency_exceptions (
    rental_id, user_id, requested_by, exception_scopes, reason,
    evidence_note, expires_at, starting_mileage
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id, p_exception_scopes,
    trim(p_reason), nullif(trim(coalesce(p_evidence_note, '')), ''),
    p_expires_at, p_starting_mileage
  ) returning * into v_exception;

  update public.rentals
  set status = 'active', starting_mileage = p_starting_mileage, ending_mileage = null
  where id = v_rental.id;
  update public.vehicles
  set status = 'rented', current_mileage = p_starting_mileage
  where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'emergency_release_exception_created',
    jsonb_build_object(
      'exception_id', v_exception.id,
      'scopes', p_exception_scopes,
      'reason', trim(p_reason),
      'expires_at', p_expires_at,
      'starting_mileage', p_starting_mileage
    )
  );

  insert into public.admin_audit_logs (
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id, metadata
  ) values (
    v_admin_id, v_admin.email, v_admin.role,
    'rental.emergency_exception_created', 'rental', v_rental.id::text,
    jsonb_build_object('exception_id', v_exception.id, 'scopes', p_exception_scopes, 'expires_at', p_expires_at)
  );

  insert into public.admin_notification_events (event_type, source_id, rental_id, dedupe_key)
  values ('emergency_exception_created', v_exception.id, v_rental.id, 'emergency_exception:' || v_exception.id::text)
  on conflict (dedupe_key) do nothing;

  return v_exception;
end;
$$;

create or replace function public.admin_resolve_rental_emergency_exception_scope(
  p_exception_id uuid,
  p_scope text,
  p_resolution_note text default null
) returns public.rental_emergency_exceptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_exception public.rental_emergency_exceptions%rowtype;
  v_resolved text[];
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_exception from public.rental_emergency_exceptions
    where id = p_exception_id for update;
  if not found then raise exception 'Emergency exception not found.'; end if;
  if v_exception.status <> 'active' then raise exception 'This exception is no longer active.'; end if;
  if not (p_scope = any(v_exception.exception_scopes)) then raise exception 'That scope is not part of this exception.'; end if;
  if not public.rentmect_rental_requirement_complete(v_exception.rental_id, p_scope) then
    raise exception '% is not actually complete yet.', initcap(p_scope);
  end if;

  select array_agg(distinct scope order by scope) into v_resolved
  from unnest(v_exception.resolved_scopes || p_scope) scope;

  update public.rental_emergency_exceptions
  set resolved_scopes = v_resolved,
      status = case when exception_scopes <@ v_resolved then 'resolved' else 'active' end,
      resolved_at = case when exception_scopes <@ v_resolved then now() else resolved_at end,
      resolved_by = case when exception_scopes <@ v_resolved then v_admin_id else resolved_by end,
      resolution_note = coalesce(nullif(trim(coalesce(p_resolution_note, '')), ''), resolution_note),
      updated_at = now()
  where id = v_exception.id
  returning * into v_exception;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_exception.rental_id, v_exception.user_id, v_admin_id,
    'emergency_release_exception_scope_resolved',
    jsonb_build_object('exception_id', v_exception.id, 'scope', p_scope, 'status', v_exception.status)
  );
  return v_exception;
end;
$$;

revoke all on function public.rentmect_rental_requirement_complete(uuid, text) from public;
revoke all on function public.rentmect_active_exception_covers(uuid, text) from public;
revoke all on function public.admin_activate_rental_with_emergency_exception(uuid, text[], text, text, timestamptz, integer, text) from public;
revoke all on function public.admin_resolve_rental_emergency_exception_scope(uuid, text, text) from public;
grant execute on function public.rentmect_rental_requirement_complete(uuid, text) to authenticated, service_role;
grant execute on function public.rentmect_active_exception_covers(uuid, text) to authenticated, service_role;
grant execute on function public.admin_activate_rental_with_emergency_exception(uuid, text[], text, text, timestamptz, integer, text) to authenticated;
grant execute on function public.admin_resolve_rental_emergency_exception_scope(uuid, text, text) to authenticated;

-- Add the critical notification type while preserving the existing queue.
alter table public.admin_notification_events
  drop constraint if exists admin_notification_events_event_type_check;
alter table public.admin_notification_events
  add constraint admin_notification_events_event_type_check
  check (event_type in (
    'new_booking', 'document_pending_review', 'return_due_today', 'maintenance_due',
    'extension_requested', 'extension_approved', 'emergency_exception_created'
  ));
