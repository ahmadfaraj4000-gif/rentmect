-- Stripe Identity renter verification and pickup enforcement.
-- Run after production_rls_policies.sql, rental_workflow_security_hardening.sql,
-- fix_vehicle_availability_buffer_rules.sql, and admin_audit_and_deposit_controls.sql.

alter table public.profiles
  add column if not exists stripe_identity_verification_session_id text,
  add column if not exists identity_verification_status text not null default 'unverified',
  add column if not exists identity_verified_at timestamptz,
  add column if not exists identity_verification_updated_at timestamptz,
  add column if not exists identity_verification_error_code text,
  add column if not exists identity_verification_livemode boolean;

update public.profiles
set identity_verification_status = 'unverified'
where identity_verification_status is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_identity_verification_status_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_identity_verification_status_check
      check (identity_verification_status in ('unverified', 'requires_input', 'processing', 'verified', 'canceled', 'redacted'));
  end if;
end $$;

create unique index if not exists profiles_stripe_identity_session_unique
  on public.profiles (stripe_identity_verification_session_id)
  where stripe_identity_verification_session_id is not null;

create index if not exists profiles_identity_status_idx
  on public.profiles (identity_verification_status, identity_verification_updated_at desc);

create or replace function public.rentmect_identity_is_verified(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where profiles.id = p_user_id
      and profiles.identity_verification_status = 'verified'
      and profiles.identity_verified_at is not null
  );
$$;

revoke all on function public.rentmect_identity_is_verified(uuid) from public;
grant execute on function public.rentmect_identity_is_verified(uuid) to authenticated, service_role;

-- No customer, staff account, or background service can release a vehicle
-- without Stripe Identity verification. Admin overrides remain available for
-- other checklist items only after identity is verified.
create or replace function public.enforce_identity_before_vehicle_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(coalesce(new.status, '')) in ('ready_for_pickup', 'active')
     and (tg_op = 'INSERT' or lower(coalesce(new.status, '')) is distinct from lower(coalesce(old.status, '')))
     and not public.rentmect_identity_is_verified(new.user_id)
     and not public.rentmect_active_exception_covers(new.id, 'identity') then
    raise exception 'Stripe Identity verification is required before vehicle pickup.';
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_require_identity_before_release on public.rentals;
create trigger rentals_require_identity_before_release
before insert or update on public.rentals
for each row execute function public.enforce_identity_before_vehicle_release();

-- Replace the final global readiness function so document approval remains
-- successful while identity is still pending; it simply waits to mark ready.
create or replace function public.sync_rental_ready_for_pickup_global(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
begin
  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;

  if not found then return null; end if;
  if lower(coalesce(v_rental.status, '')) not in ('documents_needed', 'document_review', 'approved') then
    return v_rental;
  end if;
  if not public.rentmect_identity_is_verified(v_rental.user_id) then
    return v_rental;
  end if;
  if not exists (
    select 1 from public.profiles
    where profiles.id = v_rental.user_id and coalesce(profiles.phone_verified, false)
  ) then
    return v_rental;
  end if;
  if not coalesce(v_rental.agreement_signed, false)
     or lower(coalesce(v_rental.payment_status, '')) <> 'paid' then
    return v_rental;
  end if;
  if not exists (
    select 1 from (
      select rental_documents.status
      from public.rental_documents
      where rental_documents.user_id = v_rental.user_id
        and rental_documents.document_type = 'license'
      order by rental_documents.created_at desc nulls last limit 1
    ) latest_license
    where lower(coalesce(latest_license.status, '')) = 'approved'
  ) or not exists (
    select 1 from (
      select rental_documents.status
      from public.rental_documents
      where rental_documents.rental_id = v_rental.id
        and rental_documents.user_id = v_rental.user_id
        and rental_documents.document_type = 'insurance'
      order by rental_documents.created_at desc nulls last limit 1
    ) latest_insurance
    where lower(coalesce(latest_insurance.status, '')) = 'approved'
  ) then
    return v_rental;
  end if;

  update public.rentals
  set status = 'ready_for_pickup'
  where id = v_rental.id
  returning * into v_rental;

  update public.vehicles
  set status = 'reserved'
  where id = v_rental.vehicle_id
    and coalesce(lower(status), 'available') not in ('maintenance', 'unavailable', 'inactive');

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    auth.uid(),
    'rental_auto_ready_for_pickup',
    jsonb_build_object('source', 'sync_rental_ready_for_pickup_global', 'identity_verified', true)
  );
  return v_rental;
end;
$$;

revoke all on function public.sync_rental_ready_for_pickup_global(uuid) from public;
grant execute on function public.sync_rental_ready_for_pickup_global(uuid) to authenticated, service_role;

create or replace function public.sync_rentals_after_identity_verified()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental_id uuid;
begin
  if new.identity_verification_status = 'verified'
     and old.identity_verification_status is distinct from 'verified' then
    for v_rental_id in
      select rentals.id from public.rentals
      where rentals.user_id = new.id
        and lower(coalesce(rentals.status, '')) in ('documents_needed', 'document_review', 'approved')
    loop
      perform public.sync_rental_ready_for_pickup_global(v_rental_id);
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_sync_rentals_after_identity on public.profiles;
create trigger profiles_sync_rentals_after_identity
after update of identity_verification_status on public.profiles
for each row execute function public.sync_rentals_after_identity_verified();
