-- TollSpot may know a plate before the local fleet record has its full plate
-- metadata. Rent Me CT vehicle names already carry a plate/reference suffix
-- (for example "#123"). Use it only when the provider plate resolves to
-- exactly one enabled real vehicle; ambiguous matches remain exceptions.

create or replace function public.service_match_tollspot_transaction(
  p_transaction_id uuid
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transaction public.tollspot_transactions%rowtype;
  v_vehicle_id uuid;
  v_candidate_count integer := 0;
  v_vehicle_candidate_count integer := 0;
  v_rental_id uuid;
  v_match_method text;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required.'; end if;
  select * into v_transaction from public.tollspot_transactions
  where id = p_transaction_id for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then return v_transaction; end if;

  select mappings.vehicle_id into v_vehicle_id
  from public.tollspot_vehicle_mappings mappings
  where mappings.active
    and mappings.tollspot_vehicle_id = v_transaction.tollspot_vehicle_id
  limit 1;
  if v_vehicle_id is not null then
    v_match_method := 'provider_vehicle_id';
  else
    select assignments.vehicle_id into v_vehicle_id
    from public.tollspot_plate_assignments assignments
    where upper(assignments.plate_number) = upper(coalesce(v_transaction.license_plate, ''))
      and (nullif(v_transaction.license_plate_state, '') is null
        or upper(coalesce(assignments.plate_state, '')) = upper(v_transaction.license_plate_state))
      and (nullif(v_transaction.license_plate_country, '') is null
        or upper(coalesce(assignments.plate_country, '')) = upper(v_transaction.license_plate_country))
      and v_transaction.occurred_at >= assignments.assigned_at
      and (assignments.removed_at is null or v_transaction.occurred_at < assignments.removed_at)
    order by assignments.assigned_at desc
    limit 1;
    if v_vehicle_id is not null then v_match_method := 'plate_assignment'; end if;
  end if;

  if v_vehicle_id is null
     and length(regexp_replace(coalesce(v_transaction.license_plate, ''), '[^A-Za-z0-9]', '', 'g')) >= 3 then
    select count(*), min(candidates.id::text)::uuid
    into v_vehicle_candidate_count, v_vehicle_id
    from (
      select vehicles.id
      from public.vehicles
      where vehicles.tollspot_enabled
        and lower(coalesce(vehicles.status, '')) <> 'test'
        and length(coalesce(substring(vehicles.name from '#([A-Za-z0-9]{3,})[[:space:]]*$'), '')) >= 3
        and upper(regexp_replace(v_transaction.license_plate, '[^A-Za-z0-9]', '', 'g'))
          like '%' || upper(substring(vehicles.name from '#([A-Za-z0-9]{3,})[[:space:]]*$'))
    ) candidates;

    if v_vehicle_candidate_count = 1 then
      v_match_method := 'fleet_reference_suffix';
    else
      v_vehicle_id := null;
    end if;
  end if;

  if v_vehicle_id is null then
    update public.tollspot_transactions
    set status = 'needs_review', vehicle_id = null, rental_id = null,
        match_method = null, match_candidate_count = v_vehicle_candidate_count,
        review_reason = case
          when v_vehicle_candidate_count > 1
            then 'Fleet reference matched more than one local vehicle.'
          else 'No local vehicle mapping matched the provider charge.'
        end,
        updated_at = now()
    where id = p_transaction_id returning * into v_transaction;
    return v_transaction;
  end if;

  select count(*), min(rentals.id::text)::uuid
  into v_candidate_count, v_rental_id
  from public.rentals rentals
  where rentals.vehicle_id = v_vehicle_id
    and lower(coalesce(rentals.status, '')) <> 'cancelled'
    and rentals.pickup_date is not null
    and rentals.return_date is not null
    and v_transaction.occurred_at >=
      (public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time)
        at time zone 'America/New_York')
    and v_transaction.occurred_at <=
      (public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
        at time zone 'America/New_York');

  update public.tollspot_transactions
  set vehicle_id = v_vehicle_id,
      rental_id = case when v_candidate_count = 1 then v_rental_id else null end,
      status = case
        when v_candidate_count = 1 and coalesce(transaction_type, 'TOLLS') = 'TOLLS'
          then 'matched'
        else 'needs_review'
      end,
      match_method = v_match_method,
      match_candidate_count = v_candidate_count,
      review_reason = case
        when coalesce(transaction_type, 'TOLLS') <> 'TOLLS'
          then 'Parking and violation transactions require explicit review.'
        when v_candidate_count = 0
          then 'No rental interval contains the transaction occurrence time.'
        when v_candidate_count > 1
          then 'More than one rental interval contains the transaction occurrence time.'
        else null
      end,
      updated_at = now()
  where id = p_transaction_id
  returning * into v_transaction;

  if v_transaction.status = 'matched' then
    return public.service_create_tollspot_charge(v_transaction.id);
  end if;
  return v_transaction;
end;
$$;

revoke all on function public.service_match_tollspot_transaction(uuid) from public;
grant execute on function public.service_match_tollspot_transaction(uuid) to service_role;

comment on function public.service_match_tollspot_transaction(uuid) is
  'Matches TollSpot charges by provider mapping, plate assignment, or a unique fleet reference suffix; then creates the customer rental charge automatically.';
