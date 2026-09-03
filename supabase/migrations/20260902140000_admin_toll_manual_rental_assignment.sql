begin;

-- A reviewed TollSpot row must be assignable even when the provider omitted
-- every vehicle identifier. The admin supplies the rental and a durable
-- verification note; this function performs the match, charge creation, and
-- audit writes in one locked transaction so the toll cannot be charged twice.
create or replace function public.admin_assign_tollspot_transaction_to_rental(
  p_transaction_id uuid,
  p_rental_id uuid,
  p_verification_note text
) returns public.tollspot_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_transaction public.tollspot_transactions%rowtype;
  v_rental public.rentals%rowtype;
  v_charge public.rental_charge_items%rowtype;
  v_vehicle_id uuid;
  v_vehicle_matches boolean := false;
  v_inside_possession boolean := false;
  v_note text := trim(coalesce(p_verification_note, ''));
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if not public.rentmect_has_permission('charge.manage') then
    raise exception 'Rental charge permission is required.';
  end if;
  if length(v_note) < 10 then
    raise exception 'Explain how you verified the customer and rental (at least 10 characters).';
  end if;

  select * into v_admin
  from public.profiles
  where id = auth.uid();

  select * into v_transaction
  from public.tollspot_transactions
  where id = p_transaction_id
  for update;
  if not found then raise exception 'TollSpot transaction not found.'; end if;
  if v_transaction.status in ('charge_created', 'paid', 'ignored') then
    if v_transaction.rental_id = p_rental_id then
      return v_transaction;
    end if;
    raise exception 'This toll has already been finalized for a different rental. No change was made.';
  end if;
  if upper(coalesce(v_transaction.transaction_type, 'TOLLS')) <> 'TOLLS' then
    raise exception 'Only toll transactions can be assigned to customer rentals.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;
  if v_rental.user_id is null then
    raise exception 'The selected rental has no customer account.';
  end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'A toll cannot be assigned to a cancelled rental.';
  end if;
  if v_rental.vehicle_id is null then
    raise exception 'The selected rental has no fleet vehicle.';
  end if;

  -- When the provider already identified a car, do not let a manual review
  -- silently move that car's toll to an unrelated rental. Vehicle switches are
  -- accepted through the possession ledger.
  if v_transaction.vehicle_id is not null then
    select (
      v_rental.vehicle_id = v_transaction.vehicle_id
      or exists (
        select 1
        from public.rental_vehicle_assignments assignment
        where assignment.rental_id = v_rental.id
          and assignment.vehicle_id = v_transaction.vehicle_id
      )
    ) into v_vehicle_matches;
    if not v_vehicle_matches then
      raise exception 'The selected rental never possessed the vehicle identified on this toll. Verify the car first.';
    end if;
    v_vehicle_id := v_transaction.vehicle_id;
  else
    -- An explicit rental selection also identifies the otherwise anonymous car.
    v_vehicle_id := v_rental.vehicle_id;
    v_vehicle_matches := true;
  end if;

  v_inside_possession := public.rental_vehicle_possession_contains(
    v_rental.id, v_vehicle_id, v_transaction.occurred_at
  );

  select * into v_charge
  from public.rental_charge_items
  where source_type = 'tollspot'
    and source_reference = v_transaction.tollspot_transaction_id
  limit 1
  for update;

  if found and v_charge.rental_id is distinct from v_rental.id then
    raise exception 'This TollSpot transaction already belongs to a different rental charge. No change was made.';
  end if;

  if not found then
    insert into public.rental_charge_items (
      rental_id, user_id, name, charge_type, description, amount, taxable,
      tax_amount, total_amount, included_in_initial_payment, status,
      created_by, source_type, source_reference
    ) values (
      v_rental.id,
      v_rental.user_id,
      coalesce(nullif(trim(v_transaction.exit_location), ''),
        nullif(trim(v_transaction.road_or_plaza), ''), 'Toll charge'),
      'toll',
      concat_ws(' • ', nullif(trim(v_transaction.agency), ''),
        'TollSpot transaction ' || v_transaction.tollspot_transaction_id,
        'Manually verified: ' || v_note),
      round(v_transaction.total_amount, 2),
      false,
      0,
      round(v_transaction.total_amount, 2),
      false,
      'pending',
      auth.uid(),
      'tollspot',
      v_transaction.tollspot_transaction_id
    )
    returning * into v_charge;
  end if;

  update public.tollspot_transactions
  set vehicle_id = v_vehicle_id,
      rental_id = v_rental.id,
      status = case
        when lower(coalesce(v_charge.status, '')) = 'paid' then 'paid'
        when lower(coalesce(v_charge.status, '')) = 'waived' then 'ignored'
        else 'charge_created'
      end,
      match_method = 'admin_verified_rental',
      match_candidate_count = 1,
      review_reason = null,
      ignored_reason = null,
      rental_charge_item_id = v_charge.id,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = v_transaction.id
  returning * into v_transaction;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id,
    v_rental.user_id,
    auth.uid(),
    'admin_tollspot_rental_assigned',
    jsonb_build_object(
      'charge_id', v_charge.id,
      'tollspot_transaction_id', v_transaction.tollspot_transaction_id,
      'vehicle_id', v_vehicle_id,
      'amount', v_transaction.total_amount,
      'occurred_at', v_transaction.occurred_at,
      'transponder_number', v_transaction.transponder_number,
      'license_plate', v_transaction.license_plate,
      'verification_note', v_note,
      'inside_recorded_possession', v_inside_possession,
      'actor_email', v_admin.email
    )
  );

  insert into public.admin_audit_logs (
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id, metadata
  ) values (
    auth.uid(), v_admin.email, v_admin.role,
    'tollspot.rental_assigned', 'rental', v_rental.id::text,
    jsonb_build_object(
      'tollspot_transaction_id', v_transaction.tollspot_transaction_id,
      'charge_id', v_charge.id,
      'vehicle_id', v_vehicle_id,
      'amount', v_transaction.total_amount,
      'occurred_at', v_transaction.occurred_at,
      'inside_recorded_possession', v_inside_possession,
      'verification_note', v_note
    )
  );

  return v_transaction;
end;
$$;

revoke all on function public.admin_assign_tollspot_transaction_to_rental(uuid, uuid, text)
  from public, anon;
grant execute on function public.admin_assign_tollspot_transaction_to_rental(uuid, uuid, text)
  to authenticated;

comment on function public.admin_assign_tollspot_transaction_to_rental(uuid, uuid, text) is
  'Atomically assigns a reviewed toll to a rental, creates one idempotent charge, and attributes the decision to the reviewing admin.';

notify pgrst, 'reload schema';

commit;
