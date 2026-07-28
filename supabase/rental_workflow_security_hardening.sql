-- Narrow customer rental workflow writes to server-validated RPCs.
-- Run after rentmect_hardening.sql and production_rls_policies.sql.

create or replace function public.sync_customer_rental_document_review_status(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to update a rental.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('documents_needed', 'document_review') then
    raise exception 'This rental is not waiting for document review.';
  end if;

  if not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where user_id = v_user_id
        and document_type = 'license'
      order by created_at desc nulls last
      limit 1
    ) latest_license
    where lower(coalesce(latest_license.status, '')) <> 'rejected'
  ) or not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where rental_id = p_rental_id
        and user_id = v_user_id
        and document_type = 'insurance'
      order by created_at desc nulls last
      limit 1
    ) latest_insurance
    where lower(coalesce(latest_insurance.status, '')) <> 'rejected'
  ) then
    raise exception 'Driver license and insurance uploads are required.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'documents_needed' then
    update public.rentals
      set status = 'document_review'
      where id = p_rental_id
      returning * into v_rental;

    insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
    values (
      p_rental_id,
      v_user_id,
      v_user_id,
      'rental_document_review_requested',
      jsonb_build_object('source', 'sync_customer_rental_document_review_status')
    );
  end if;

  return v_rental;
end;
$$;

revoke all on function public.sync_customer_rental_document_review_status(uuid) from public;
grant execute on function public.sync_customer_rental_document_review_status(uuid) to authenticated;

create or replace function public.mark_customer_rental_ready_for_pickup_if_eligible(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to update a rental.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'ready_for_pickup' then
    return v_rental;
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('documents_needed', 'document_review', 'approved') then
    raise exception 'This rental cannot be marked ready for pickup.';
  end if;

  if not coalesce(v_rental.agreement_signed, false) then
    raise exception 'The rental agreement must be signed first.';
  end if;

  if lower(coalesce(v_rental.payment_status, '')) <> 'paid' then
    raise exception 'Rental payment must be paid first.';
  end if;

  if not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where user_id = v_user_id
        and document_type = 'license'
      order by created_at desc nulls last
      limit 1
    ) latest_license
    where lower(coalesce(latest_license.status, '')) = 'approved'
  ) or not exists (
    select 1
    from (
      select rental_documents.status
      from public.rental_documents
      where rental_id = p_rental_id
        and user_id = v_user_id
        and document_type = 'insurance'
      order by created_at desc nulls last
      limit 1
    ) latest_insurance
    where lower(coalesce(latest_insurance.status, '')) = 'approved'
  ) then
    raise exception 'Approved driver license and insurance documents are required.';
  end if;

  update public.rentals
    set status = 'ready_for_pickup'
    where id = p_rental_id
    returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    p_rental_id,
    v_user_id,
    v_user_id,
    'rental_ready_for_pickup',
    jsonb_build_object('source', 'mark_customer_rental_ready_for_pickup_if_eligible')
  );

  return v_rental;
end;
$$;

revoke all on function public.mark_customer_rental_ready_for_pickup_if_eligible(uuid) from public;
grant execute on function public.mark_customer_rental_ready_for_pickup_if_eligible(uuid) to authenticated;

create or replace function public.initiate_customer_rental_return(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_return_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to update a rental.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'return_initiated' then
    return v_rental;
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Only an active rental can start a return.';
  end if;

  if v_rental.return_date is null then
    raise exception 'Rental return time is missing.';
  end if;

  if exists (
    select 1
    from public.rental_extension_requests
    where rental_id = p_rental_id
      and user_id = v_user_id
      and status = 'pending'
      and coalesce(request_kind, 'same_vehicle_extension') = 'same_vehicle_extension'
  ) then
    raise exception 'Return confirmation is locked while the extension request is pending.';
  end if;

  v_return_at := public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
    at time zone 'America/New_York';

  if now() < v_return_at then
    raise exception 'Return confirmation is not available until the booked return time.';
  end if;

  update public.rentals
    set status = 'return_initiated'
    where id = p_rental_id
    returning * into v_rental;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    p_rental_id,
    v_user_id,
    v_user_id,
    'rental_return_initiated',
    jsonb_build_object('source', 'initiate_customer_rental_return')
  );

  return v_rental;
end;
$$;

revoke all on function public.initiate_customer_rental_return(uuid) from public;
grant execute on function public.initiate_customer_rental_return(uuid) to authenticated;

create or replace function public.admin_mark_rental_active(
  p_rental_id uuid
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

  if lower(coalesce(v_rental.status, '')) not in ('document_review', 'approved', 'ready_for_pickup') then
    raise exception 'Only reviewed rentals can be marked active.';
  end if;

  if not coalesce(v_rental.agreement_signed, false)
     or lower(coalesce(v_rental.payment_status, '')) <> 'paid' then
    raise exception 'Signed agreement and paid rental are required.';
  end if;

  if not exists (
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
  ) then
    raise exception 'Approved driver license and insurance documents are required before release.';
  end if;

  update public.rentals set status = 'active'
    where id = v_rental.id returning * into v_rental;
  update public.vehicles set status = 'rented' where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_marked_active', '{}'::jsonb);
  return v_rental;
end;
$$;

revoke all on function public.admin_mark_rental_active(uuid) from public;
grant execute on function public.admin_mark_rental_active(uuid) to authenticated;

create or replace function public.admin_complete_rental_return(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue', 'return_initiated') then
    raise exception 'Only out or returned rentals can be completed.';
  end if;
  update public.rentals set status = 'completed' where id = v_rental.id returning * into v_rental;
  update public.vehicles set status = 'available' where id = v_rental.vehicle_id and lower(coalesce(status, '')) = 'rented';
  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_completed', '{}'::jsonb);
  return v_rental;
end;
$$;

revoke all on function public.admin_complete_rental_return(uuid) from public;
grant execute on function public.admin_complete_rental_return(uuid) to authenticated;

create or replace function public.admin_cancel_rental(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare v_admin_id uuid := auth.uid(); v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  select * into v_rental from public.rentals where id = p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) in ('completed', 'cancelled', 'active', 'overdue', 'return_initiated') then
    raise exception 'This rental cannot be cancelled from the guarded action.';
  end if;
  update public.rentals set status = 'cancelled' where id = v_rental.id returning * into v_rental;
  update public.vehicles set status = 'available' where id = v_rental.vehicle_id and lower(coalesce(status, '')) = 'reserved';
  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_cancelled', '{}'::jsonb);
  return v_rental;
end;
$$;

revoke all on function public.admin_cancel_rental(uuid) from public;
grant execute on function public.admin_cancel_rental(uuid) to authenticated;

-- The client creates rentals via create_rental_with_lock and moves workflow state
-- through the functions above. Keep direct rental writes for admins only.
drop policy if exists "Users can create own rentals" on public.rentals;
drop policy if exists "Users can update own pending rentals" on public.rentals;
drop policy if exists "Customers can update their rental workflow fields" on public.rentals;

drop policy if exists "Admins can update rentals" on public.rentals;
create policy "Admins can update rentals"
  on public.rentals
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());
