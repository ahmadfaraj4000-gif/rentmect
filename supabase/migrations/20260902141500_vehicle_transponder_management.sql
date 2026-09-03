begin;

-- One current transponder per fleet vehicle. Historical mappings remain in the
-- table as inactive records so earlier attribution decisions stay auditable.
with ranked as (
  select
    mapping.id,
    row_number() over (
      partition by mapping.vehicle_id
      order by mapping.verified_at desc, mapping.updated_at desc, mapping.created_at desc
    ) as position
  from public.tollspot_transponder_mappings mapping
  where mapping.active
)
update public.tollspot_transponder_mappings mapping
set active = false,
    updated_at = now()
from ranked
where mapping.id = ranked.id
  and ranked.position > 1;

create unique index if not exists tollspot_transponder_mappings_one_active_vehicle_uidx
  on public.tollspot_transponder_mappings (vehicle_id)
  where active;

drop policy if exists "Admins read verified TollSpot transponders"
  on public.tollspot_transponder_mappings;
create policy "Admins read verified TollSpot transponders"
on public.tollspot_transponder_mappings
for select
to authenticated
using (public.is_admin());

grant select on public.tollspot_transponder_mappings to authenticated;

-- The service-only mutation keeps replacement/clearing atomic. The Edge
-- Function authenticates the administrator, passes the actor, then safely
-- reprocesses unresolved tolls after this transaction commits.
create or replace function public.service_set_tollspot_vehicle_transponder(
  p_vehicle_id uuid,
  p_transponder_number text,
  p_actor_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transponder text := upper(regexp_replace(trim(coalesce(p_transponder_number, '')), '[^0-9A-Za-z]', '', 'g'));
  v_provider_vehicle_id text;
  v_existing public.tollspot_transponder_mappings%rowtype;
  v_previous text[] := '{}'::text[];
  v_first_seen timestamptz;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;
  if p_vehicle_id is null then
    raise exception 'Choose a valid Rent Me CT fleet vehicle.';
  end if;
  if p_actor_id is null then
    raise exception 'An authenticated administrator is required.';
  end if;
  if length(v_transponder) > 200 then
    raise exception 'The transponder number is too long.';
  end if;

  perform 1 from public.vehicles vehicle where vehicle.id = p_vehicle_id;
  if not found then raise exception 'Fleet vehicle not found.'; end if;

  perform 1
  from public.tollspot_transponder_mappings mapping
  where mapping.vehicle_id = p_vehicle_id
     or (v_transponder <> '' and mapping.transponder_number = v_transponder)
  order by mapping.id
  for update;

  select coalesce(array_agg(mapping.transponder_number order by mapping.verified_at desc), '{}'::text[])
  into v_previous
  from public.tollspot_transponder_mappings mapping
  where mapping.vehicle_id = p_vehicle_id
    and mapping.active;

  if v_transponder = '' then
    update public.tollspot_transponder_mappings
    set active = false,
        verified_by = p_actor_id,
        verified_at = now(),
        updated_at = now()
    where vehicle_id = p_vehicle_id
      and active;

    return jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'transponder_number', null,
      'previous_transponders', to_jsonb(v_previous),
      'cleared', true
    );
  end if;

  select * into v_existing
  from public.tollspot_transponder_mappings mapping
  where mapping.transponder_number = v_transponder
  for update;

  if found and v_existing.active and v_existing.vehicle_id <> p_vehicle_id then
    raise exception 'This transponder is already verified to another vehicle. Clear that vehicle first.';
  end if;

  select mapping.tollspot_vehicle_id into v_provider_vehicle_id
  from public.tollspot_vehicle_mappings mapping
  where mapping.vehicle_id = p_vehicle_id
    and mapping.active
  limit 1;
  if v_provider_vehicle_id is null then
    raise exception 'Sync this fleet vehicle with TollSpot before saving its transponder.';
  end if;

  select min(transaction.occurred_at) into v_first_seen
  from public.tollspot_transactions transaction
  where upper(regexp_replace(coalesce(transaction.transponder_number, ''), '[^0-9A-Za-z]', '', 'g')) = v_transponder;

  update public.tollspot_transponder_mappings
  set active = false,
      verified_by = p_actor_id,
      verified_at = now(),
      updated_at = now()
  where vehicle_id = p_vehicle_id
    and active
    and transponder_number <> v_transponder;

  insert into public.tollspot_transponder_mappings (
    transponder_number,
    vehicle_id,
    tollspot_vehicle_id,
    first_seen_at,
    verified_by,
    verified_at,
    active,
    updated_at
  ) values (
    v_transponder,
    p_vehicle_id,
    v_provider_vehicle_id,
    coalesce(v_first_seen, now()),
    p_actor_id,
    now(),
    true,
    now()
  )
  on conflict (transponder_number) do update set
    vehicle_id = excluded.vehicle_id,
    tollspot_vehicle_id = excluded.tollspot_vehicle_id,
    first_seen_at = least(
      coalesce(public.tollspot_transponder_mappings.first_seen_at, excluded.first_seen_at),
      excluded.first_seen_at
    ),
    verified_by = excluded.verified_by,
    verified_at = excluded.verified_at,
    active = true,
    updated_at = excluded.updated_at;

  return jsonb_build_object(
    'vehicle_id', p_vehicle_id,
    'transponder_number', v_transponder,
    'tollspot_vehicle_id', v_provider_vehicle_id,
    'previous_transponders', to_jsonb(v_previous),
    'cleared', false
  );
end;
$$;

revoke all on function public.service_set_tollspot_vehicle_transponder(uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.service_set_tollspot_vehicle_transponder(uuid, text, uuid)
  to service_role;

comment on function public.service_set_tollspot_vehicle_transponder(uuid, text, uuid) is
  'Service-only atomic setter for the single active TollSpot transponder displayed on each fleet vehicle.';

-- Match alphanumeric transponders case-insensitively while retaining the full
-- provider value for staff review.
create or replace function public.service_apply_tollspot_transponder_mappings(
  p_transaction_ids uuid[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  with resolved as (
    select transaction.id, mapping.tollspot_vehicle_id
    from public.tollspot_transactions transaction
    join public.tollspot_transponder_mappings mapping
      on mapping.active
     and upper(mapping.transponder_number) = upper(regexp_replace(
       coalesce(transaction.transponder_number, ''), '[^0-9A-Za-z]', '', 'g'
     ))
    where transaction.id = any(coalesce(p_transaction_ids, '{}'::uuid[]))
      and transaction.status not in ('charge_created', 'paid', 'ignored')
      and (mapping.first_seen_at is null or transaction.occurred_at >= mapping.first_seen_at)
  )
  update public.tollspot_transactions transaction
  set tollspot_vehicle_id = resolved.tollspot_vehicle_id,
      updated_at = now()
  from resolved
  where transaction.id = resolved.id
    and transaction.tollspot_vehicle_id is distinct from resolved.tollspot_vehicle_id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.service_apply_tollspot_transponder_mappings(uuid[])
  from public, anon, authenticated;
grant execute on function public.service_apply_tollspot_transponder_mappings(uuid[])
  to service_role;

notify pgrst, 'reload schema';

commit;
