-- Allows a signed-in customer to finish the fixed Booking Preview test rental
-- without contacting Stripe or collecting money. This function cannot operate
-- on any real fleet vehicle and retains the normal verification prerequisites.
-- Run after booking_flow_test_vehicle.sql, stripe_identity_verification.sql,
-- and stripe_payments.sql.

create or replace function public.complete_booking_flow_test_payment(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_test_vehicle_id constant uuid := '00000000-0000-4000-8000-000000000015';
  v_rental public.rentals%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to complete a test booking.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id and user_id = v_user_id
  for update;

  if not found then raise exception 'Test rental not found.'; end if;
  if v_rental.vehicle_id <> v_test_vehicle_id then
    raise exception 'No-charge completion is restricted to the fixed Booking Preview test vehicle.';
  end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled test rentals cannot be completed.';
  end if;
  if v_rental.checkout_expires_at is not null and v_rental.checkout_expires_at <= now() then
    raise exception 'This test checkout session has expired.';
  end if;
  if lower(coalesce(v_rental.payment_status, '')) = 'paid' then return v_rental; end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_user_id
      and p.date_of_birth is not null
      and coalesce(p.phone_verified, false)
      and lower(coalesce(p.identity_verification_status, '')) = 'verified'
  ) then
    raise exception 'Complete profile, phone, and identity verification before finishing the test booking.';
  end if;
  if not coalesce(v_rental.agreement_signed, false) then
    raise exception 'Sign the rental agreement before finishing the test booking.';
  end if;
  if not exists (
    select 1 from public.rental_documents d
    where d.user_id = v_user_id
      and d.document_type = 'license'
      and lower(coalesce(d.status, '')) <> 'rejected'
  ) or not exists (
    select 1 from public.rental_documents d
    where d.user_id = v_user_id
      and d.rental_id = v_rental.id
      and d.document_type = 'insurance'
      and lower(coalesce(d.status, '')) <> 'rejected'
  ) then
    raise exception 'Upload the required license and insurance documents before finishing the test booking.';
  end if;

  update public.rentals
  set payment_status = 'paid',
      paid_at = coalesce(paid_at, now()),
      payment_provider = 'booking_preview_test',
      payment_amount_cents = 0,
      payment_currency = 'usd',
      deposit_status = 'pending',
      deposit_held_amount = 0
  where id = v_rental.id
  returning * into v_rental;

  update public.rental_charge_items
  set status = 'paid', payment_provider = 'booking_preview_test', paid_at = coalesce(paid_at, now()), updated_at = now()
  where rental_id = v_rental.id and included_in_initial_payment and status <> 'paid';

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id, v_user_id, v_user_id, 'booking_preview_test_payment_completed',
    jsonb_build_object(
      'vehicle_id', v_test_vehicle_id,
      'amount_collected', 0,
      'payment_provider', 'booking_preview_test'
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.complete_booking_flow_test_payment(uuid) from public;
grant execute on function public.complete_booking_flow_test_payment(uuid) to authenticated;
