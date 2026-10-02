-- Run against an isolated/staging schema with an admin fixture. Everything rolls
-- back; this test never contacts a payment provider or applies live corrections.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temporary table period_test_results (scenario text, result text);
do $test$
declare
  actor uuid:='11111111-1111-4111-8111-111111111111';
  customer uuid:='22222222-2222-4222-8222-222222222222';
  car uuid; replacement uuid; third_car uuid; rid uuid; eid uuid; key uuid; q jsonb; result jsonb;
  kind text; r public.rentals%rowtype; amount numeric; before_amount numeric; count_rows integer;
  start_day date:='2026-09-17'; end_day date:='2026-09-27';
begin
  -- Fixture inserts bypass unrelated identity/email/workflow triggers only.
  perform set_config('session_replication_role','replica',true);
  insert into auth.users(id) values(actor),(customer) on conflict do nothing;
  insert into public.profiles(id,role,staff_role,date_of_birth) values(actor,'admin','owner','1980-01-01'),(customer,'customer','customer','1980-01-01') on conflict do nothing;
  perform set_config('session_replication_role','origin',true);
  foreach kind in array array['customer_request','emergency','maintenance'] loop
    perform set_config('session_replication_role','replica',true);
    insert into public.vehicles(name,daily_rate,security_deposit,status,is_active) values('Test Buick',49,300,'available',true) returning id into car;
    insert into public.vehicles(name,daily_rate,security_deposit,status,is_active) values('Test Audi',69,500,'available',true) returning id into replacement;
    insert into public.vehicles(name,daily_rate,security_deposit,status,is_active) values('Test Third',79,500,'available',true) returning id into third_car;
    insert into public.rentals(user_id,vehicle_id,pickup_date,pickup_time,return_date,return_time,status,
      rental_total,base_rental_total,tax_amount,service_fee_total,security_deposit,deposit_held_amount,
      payment_status,paid_at,payment_amount_cents,under_25_markup_percentage,discount_amount,manual_discount_amount,cancellation_credit_amount)
    values(customer,car,start_day,'9:00 AM',end_day,'9:00 AM','active',480,490,30.48,0,300,300,
      'partially_paid',now(),65415,0,0,10,0) returning id into rid;
    insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source)
      values(rid,car,'2026-09-17 09:00 America/New_York','2026-09-27 09:00 America/New_York','initial');
    perform set_config('session_replication_role','origin',true);
    q:=public.admin_preview_vehicle_swap(rid,replacement,'2026-09-23 09:00 America/New_York',kind,'Customer agreed September 23 replacement',case when kind='customer_request' then 69 else null end);
    if (q->>'total_delta')::numeric is distinct from (case when kind='customer_request' then 85.08 else 0 end) then raise exception 'Wrong swap quote %',q; end if;
    if exists(select 1 from public.rental_pricing_periods where rental_id=rid) then raise exception 'Preview wrote pricing periods'; end if;
    if (q->>'previous_balance')::numeric<>156.33 then raise exception 'Previous debt disappeared: %',q; end if;
    key:=gen_random_uuid();
    result:=public.admin_apply_vehicle_swap(rid,replacement,'2026-09-23 09:00 America/New_York',kind,
      'Customer agreed September 23 replacement',case when kind='customer_request' then 69 else null end,key,q->>'revision');
    select * into r from public.rentals where id=rid;
    if r.pickup_date<>start_day or r.payment_amount_cents<>65415 or r.manual_discount_amount<>10 or r.security_deposit<>300 then raise exception 'Original contract, payment, discount or deposit changed'; end if;
    if r.rental_total<>(case when kind='customer_request' then 560 else 480 end) then raise exception 'Wrong rental amount %',r.rental_total; end if;
    if not exists(select 1 from public.rental_vehicle_assignments where rental_id=rid and vehicle_id=car and assigned_until='2026-09-23 09:00 America/New_York') then raise exception 'Prior assignment lost'; end if;
    if not exists(select 1 from public.rental_vehicle_swaps where id=key and recorded_at>effective_at) then raise exception 'Late entry timestamp missing'; end if;
    result:=public.admin_apply_vehicle_swap(rid,replacement,'2026-09-23 09:00 America/New_York',kind,
      'Customer agreed September 23 replacement',case when kind='customer_request' then 69 else null end,key,q->>'revision');
    if not (result->>'idempotent_replay')::boolean then raise exception 'Replay created duplicate charges'; end if;
    begin
      perform public.admin_apply_vehicle_swap(rid,third_car,'2026-09-24 09:00 America/New_York',kind,'different swap request',null,key,q->>'revision');
      raise exception 'FAILED idempotency collision';
    exception when others then if sqlerrm='FAILED idempotency collision' then raise; end if; end;
    begin
      update public.rentals set pickup_date='2026-09-23' where id=rid;
      raise exception 'FAILED original start protection';
    exception when others then if sqlerrm='FAILED original start protection' then raise; end if; end;
    begin
      update public.rentals set vehicle_id=third_car where id=rid;
      raise exception 'FAILED dedicated swap protection';
    exception when others then if sqlerrm='FAILED dedicated swap protection' then raise; end if; end;
    begin
      perform public.admin_preview_vehicle_swap(rid,third_car,'2026-09-24 09:00 America/New_York','emergency','emergency replacement requested',79);
      raise exception 'FAILED emergency repricing protection';
    exception when others then if sqlerrm='FAILED emergency repricing protection' then raise; end if; end;
    -- Default extension uses the replacement rate snapshotted when requested,
    -- even if staff later change the public fleet price. Nested rollback keeps
    -- this case independent from the courtesy-rate case below.
    begin
      insert into public.rental_extension_requests(rental_id,user_id,request_kind,status,payment_status,
        original_return_date,original_return_time,requested_return_date,requested_return_time,extension_deposit_amount)
      values(rid,customer,'same_vehicle_extension','pending','pending',end_day,'9:00 AM',end_day+2,'10:00 AM',0) returning id into eid;
      update public.vehicles set daily_rate=99 where id=replacement;
      update public.rental_extension_requests set status='approved_pending_payment' where id=eid;
      if not exists(select 1 from public.rental_extension_requests where id=eid and agreed_daily_rate=69 and extension_days=3 and extension_total_amount=220.14) then
        raise exception 'Replacement extension rate or partial-day cutoff changed';
      end if;
      perform public.record_admin_local_rental_extension_payment(eid);
      if (select sum(billing_units) from public.rental_pricing_periods where rental_id=rid)<>13 then raise exception 'Replacement rate extension lost or doubled days'; end if;
      raise exception using errcode='ZX001',message='rollback default rate scenario';
    exception when sqlstate 'ZX001' then null; end;
    -- Extension starts at the old end; only its independently agreed rate applies.
    insert into public.rental_extension_requests(rental_id,user_id,request_kind,status,payment_status,
      original_return_date,original_return_time,requested_return_date,requested_return_time,extension_deposit_amount)
      values(rid,customer,'same_vehicle_extension','pending','pending',end_day,'9:00 AM',end_day+4,'9:00 AM',0) returning id into eid;
    q:=public.admin_preview_extension_rate(eid,49);
    perform public.admin_approve_extension_agreement(eid,49,'Customer agreed to continue courtesy rate',(q->>'total_due')::numeric);
    select extension_total_amount into amount from public.rental_extension_requests where id=eid;
    if amount<>208.45 then raise exception 'Wrong separate extension quote %',amount; end if;
    q:=public.get_rental_account(rid);
    if kind<>'customer_request' and (q->>'balance_due')::numeric+amount<>364.78 then raise exception 'Prior debt and extension must total 364.78'; end if;
    select rental_total into before_amount from public.rentals where id=rid;
    if kind='maintenance' then
      perform public.record_stripe_checkout_payment('evt_test_'||eid,'checkout.session.completed','extension',eid,
        'cs_test_'||eid,'pi_test_'||eid,'cus_fixture',20845,'usd','{}');
      result:=public.record_stripe_checkout_payment('evt_test_'||eid,'checkout.session.completed','extension',eid,
        'cs_test_'||eid,'pi_test_'||eid,'cus_fixture',20845,'usd','{}');
      if result->>'reason'<>'duplicate_event' then raise exception 'Stripe replay was not idempotent'; end if;
    else
      perform public.record_admin_local_rental_extension_payment(eid);
    end if;
    result:=public.get_rental_account(rid);
    if (result->>'balance_due')::numeric<>(case when kind='customer_request' then 241.41 else 156.33 end) then raise exception 'Extension payment erased prior balance %',result; end if;
    select rental_total into amount from public.rentals where id=rid;
    if amount<>before_amount+196 then raise exception 'Extension repriced previous dates'; end if;
    if (select sum(billing_units) from public.rental_pricing_periods where rental_id=rid)<>14 then raise exception 'Duplicate rental days'; end if;
    set constraints all immediate;
    set constraints all deferred;
    insert into period_test_results values(kind||' + late entry + separate courtesy extension + prior balance','passed');
  end loop;
  -- A partial-day swap shares the purchased units rather than rounding each
  -- assignment to its own full day. Stale previews cannot be committed.
  q:=public.admin_preview_vehicle_swap(rid,third_car,'2026-09-24 15:00 America/New_York','customer_request','Customer requested afternoon swap',79);
  begin
    perform public.admin_apply_vehicle_swap(rid,third_car,'2026-09-24 15:00 America/New_York','customer_request','Customer requested afternoon swap',79,gen_random_uuid(),'stale');
    raise exception 'FAILED stale quote protection';
  exception when others then if sqlerrm='FAILED stale quote protection' then raise; end if; end;
  result:=public.admin_apply_vehicle_swap(rid,third_car,'2026-09-24 15:00 America/New_York','customer_request','Customer requested afternoon swap',79,gen_random_uuid(),q->>'revision');
  if (select sum(billing_units) from public.rental_pricing_periods where rental_id=rid)<>14 then raise exception 'Partial day double billed'; end if;
  set constraints all immediate;
  set constraints all deferred;
  begin
    update public.rental_pricing_periods set starts_at=starts_at+interval '1 hour' where rental_id=rid and source='extension';
    set constraints all immediate;
    raise exception 'FAILED continuity protection';
  exception when others then if sqlerrm='FAILED continuity protection' then raise; end if; end;
  perform set_config('request.jwt.claim.sub',customer::text,true);
  begin
    perform public.admin_preview_vehicle_swap(rid,car,'2026-09-25 09:00 America/New_York','customer_request','Unauthorized swap attempt',49);
    raise exception 'FAILED permission protection';
  exception when others then if sqlerrm='FAILED permission protection' then raise; end if; end;
  insert into period_test_results values('partial days, stale review, permission, idempotency, discount, deposit and gap guards','passed');
end; $test$;
table period_test_results;
rollback;
