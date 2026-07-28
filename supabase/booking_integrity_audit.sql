-- Non-charging scheduling audit. Run in the Supabase SQL Editor after
-- booking_integrity_guards.sql. Every fixture is rolled back at the end.
-- No Stripe/Twilio calls are made and no permanent rental is created.

begin;

do $$
declare
  v_customer_id uuid;
  v_vehicle_id uuid := gen_random_uuid();
  v_base_rental_id uuid;
  v_boundary_rental_id uuid;
  v_block_id uuid;
  v_rejected boolean;
  v_start_date date := current_date + 60;
begin
  select id into v_customer_id from public.profiles order by created_at limit 1;
  if v_customer_id is null then
    raise exception 'Audit needs at least one existing profile for the rental foreign key.';
  end if;

  insert into public.vehicles (
    id, name, brand, model, vehicle_type, daily_rate, security_deposit,
    status, description, features, image_urls, published
  ) values (
    v_vehicle_id, 'Rollback Integrity Audit Vehicle', 'Rent Me CT', 'SQL Audit',
    'Internal Test', 1, 0, 'available',
    'Temporary rollback-only fixture.', array['Audit fixture']::text[],
    array[]::text[], false
  );

  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status, deposit_status
  ) values (
    v_customer_id, v_vehicle_id, v_start_date, v_start_date + 1,
    '9:00 AM', '6:00 PM', 'documents_needed', 1, 0, 0, 'pending', 'pending'
  ) returning id into v_base_rental_id;

  -- Exact overlap must fail.
  v_rejected := false;
  begin
    insert into public.rentals (
      user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
      status, rental_total, tax_amount, security_deposit, payment_status, deposit_status
    ) values (
      v_customer_id, v_vehicle_id, v_start_date, v_start_date + 1,
      '10:00 AM', '5:00 PM', 'documents_needed', 1, 0, 0, 'pending', 'pending'
    );
  exception when others then
    v_rejected := position('Vehicle schedule conflict' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: overlapping rental was accepted.'; end if;

  -- Two hours and 59 minutes after return must still fail.
  v_rejected := false;
  begin
    insert into public.rentals (
      user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
      status, rental_total, tax_amount, security_deposit, payment_status, deposit_status
    ) values (
      v_customer_id, v_vehicle_id, v_start_date + 1, v_start_date + 2,
      '8:59 PM', '6:00 PM', 'documents_needed', 1, 0, 0, 'pending', 'pending'
    );
  exception when others then
    v_rejected := position('Vehicle schedule conflict' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: turnaround gap under three hours was accepted.'; end if;

  -- Exactly three hours after return is the first valid pickup.
  insert into public.rentals (
    user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
    status, rental_total, tax_amount, security_deposit, payment_status, deposit_status
  ) values (
    v_customer_id, v_vehicle_id, v_start_date + 1, v_start_date + 2,
    '9:00 PM', '6:00 PM', 'documents_needed', 1, 0, 0, 'pending', 'pending'
  ) returning id into v_boundary_rental_id;

  -- Extending the first rental into the boundary rental must fail atomically.
  v_rejected := false;
  begin
    update public.rentals
      set return_date = v_start_date + 2, return_time = '6:00 PM'
      where id = v_base_rental_id;
  exception when others then
    v_rejected := position('Vehicle schedule conflict' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: conflicting rental extension was accepted.'; end if;

  -- Cancelled rentals release inventory.
  update public.rentals set status = 'cancelled' where id = v_boundary_rental_id;

  -- An active admin calendar block must stop a rental/extension write.
  insert into public.vehicle_availability_blocks (
    vehicle_id, start_date, end_date, start_time, end_time, block_type, label, active
  ) values (
    v_vehicle_id, v_start_date + 1, v_start_date + 2,
    '6:00 PM', '6:00 PM', 'unavailable', 'Rollback audit block', true
  ) returning id into v_block_id;

  v_rejected := false;
  begin
    update public.rentals
      set return_date = v_start_date + 2, return_time = '6:00 PM'
      where id = v_base_rental_id;
  exception when others then
    v_rejected := position('admin calendar blocks' in sqlerrm) > 0;
  end;
  if not v_rejected then raise exception 'AUDIT FAILED: calendar-blocked extension was accepted.'; end if;

  -- Remove the block and confirm the extension can proceed safely.
  update public.vehicle_availability_blocks set active = false where id = v_block_id;
  update public.rentals
    set return_date = v_start_date + 2, return_time = '6:00 PM'
    where id = v_base_rental_id;

  raise notice 'PASS: overlap, turnaround, cancellation, calendar block, and extension guards all passed.';
end;
$$;

select 'PASS — rollback-only audit completed; no rental or payment was retained.' as audit_result;

rollback;
