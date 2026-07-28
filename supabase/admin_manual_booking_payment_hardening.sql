-- Apply after the existing booking/payment migrations.
-- The admin may record a genuinely received external payment, but cannot use
-- that action to bypass the same release procedures enforced by Stripe checkout.

create or replace function public.record_admin_local_rental_payment(
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
    raise exception 'Admin access is required to record an external payment.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be marked paid.';
  end if;

  if coalesce(lower(v_rental.payment_status), 'pending') = 'paid' then
    raise exception 'This rental is already paid.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_rental.user_id and coalesce(p.phone_verified, false)
  ) or not public.rentmect_identity_is_verified(v_rental.user_id) then
    raise exception 'Phone and identity verification must be complete before recording payment.';
  end if;

  if not coalesce(v_rental.agreement_signed, false) then
    raise exception 'The customer must sign the rental agreement before payment can be recorded.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and lower(coalesce(d.document_type, '')) in ('license', 'drivers_license', 'driver_license')
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'An approved driver license is required before recording payment.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and d.rental_id = v_rental.id
      and lower(coalesce(d.document_type, '')) = 'insurance'
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'Approved insurance for this rental is required before recording payment.';
  end if;

  update public.rentals
    set payment_status = 'paid',
        deposit_status = 'held',
        payment_provider = 'local',
        paid_at = coalesce(paid_at, now()),
        deposit_held_amount = greatest(
          coalesce(deposit_held_amount, 0),
          coalesce(security_deposit, 0)
        ),
        updated_at = now()
    where id = p_rental_id
    returning * into v_rental;

  update public.rental_charge_items
    set status = 'paid',
        payment_provider = 'local',
        paid_at = coalesce(paid_at, now()),
        updated_at = now()
    where rental_id = v_rental.id
      and included_in_initial_payment
      and status <> 'paid';

  perform public.ensure_rental_deposit_allocation(v_rental.id);

  update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and coalesce(lower(status), 'available') not in ('maintenance', 'unavailable', 'inactive');

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_local_payment_recorded',
    jsonb_build_object(
      'source', 'record_admin_local_rental_payment',
      'procedures_verified', true
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.record_admin_local_rental_payment(uuid) from public;
grant execute on function public.record_admin_local_rental_payment(uuid) to authenticated;
