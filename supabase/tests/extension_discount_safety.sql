-- ISOLATED DATABASE ONLY. Full schema and all production triggers required.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
\ir fixtures/account_fixture.sql
create temporary table extension_safety_results(scenario text,result text);
do $test$
declare rid uuid; cid uuid; eid uuid; key uuid; q jsonb; result jsonb;
begin
  rid:=pg_temp.account_fixture(300,400);
  insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,tax_amount,total_amount,status,source_type,source_reference)
    select id,user_id,'Synthetic late fee','late_fee',25,1.59,26.59,'pending','late_return',id||':late-fee'
    from rentals where id=rid returning id into cid;
  q:=public.admin_preview_rental_extension(rid,current_date+7,'9:00 AM',69,'Customer approved seven more days');
  if (q->>'late_charges_removed')::numeric<>26.59 or (q->>'total_due')::numeric<>927.34 then
    raise exception 'Extension preview includes fees that the schedule update will remove: %',q;
  end if;
  result:=public.admin_apply_rental_extension(rid,current_date+7,'9:00 AM',69,'Customer approved seven more days',gen_random_uuid(),q->>'revision');
  if result->'settlement'->>'balance_due'<>q->>'total_due'
    or (select status from rental_charge_items where id=cid)<>'waived' then
    raise exception 'Extension quote and saved balance disagree.';
  end if;
  insert into extension_safety_results values('Overdue extension preview matches saved balance after existing late-fee withdrawal','passed');

  rid:=pg_temp.account_fixture(300,400);
  result:=public.sync_rental_remaining_balance(rid);
  cid:=(result->>'balance_charge_id')::uuid;
  update rental_charge_items set status='checkout_open',stripe_checkout_session_id='cs_synthetic',payment_amount_cents=41367 where id=cid;
  key:=gen_random_uuid();
  begin
    perform public.admin_apply_manual_rental_discount(rid,'fixed',40,'Customer discount agreed',key,auth.uid());
    raise exception 'FAIL: discounted an active payment link';
  exception when others then
    if sqlerrm<>'Expire the open payment attempt through the protected discount action before saving.' then raise; end if;
  end;
  update rental_charge_items set status='pending',stripe_checkout_session_id=null,payment_amount_cents=null where id=cid;
  perform public.admin_apply_manual_rental_discount(rid,'fixed',40,'Customer discount agreed',key,auth.uid());
  result:=public.admin_apply_manual_rental_discount(rid,'fixed',40,'Customer discount agreed',key,auth.uid());
  if not (result->>'idempotent_replay')::boolean then raise exception 'Discount retry reapplied the adjustment.'; end if;
  begin
    perform public.admin_apply_manual_rental_discount(rid,'fixed',41,'Customer discount agreed',key,auth.uid());
    raise exception 'FAIL: changed discount reused committed key';
  exception when others then
    if sqlerrm<>'Idempotency key already used for a different discount.' then raise; end if;
  end;
  insert into extension_safety_results values('Discount rejects active checkout, allows retired attempt, and binds retries to original amount','passed');

  rid:=pg_temp.account_fixture(300,813.67);
  insert into rental_extension_requests(rental_id,user_id,request_kind,status,payment_status,
    original_return_date,original_return_time,requested_return_date,requested_return_time)
    select id,user_id,'same_vehicle_extension','pending','pending',return_date,return_time,return_date+7,return_time
    from rentals where id=rid returning id into eid;
  insert into rental_documents(rental_id,user_id,document_type,status,insurance_packet_id,insurance_coverage_type,extension_request_id,file_path)
    select rid,user_id,'insurance','approved',gen_random_uuid(),'combined',eid,'synthetic/insurance.pdf' from rentals where id=rid;
  update vehicles set maintenance_lock_active=true where id=(select vehicle_id from rentals where id=rid);
  begin
    perform public.decide_admin_rental_extension(eid,true,null);
    raise exception 'FAIL: customer extension ignored maintenance lock';
  exception when others then
    if sqlerrm not like 'Extension unavailable:%' then raise; end if;
  end;
  update vehicles set maintenance_lock_active=false where id=(select vehicle_id from rentals where id=rid);
  perform public.decide_admin_rental_extension(eid,true,null);
  begin
    perform public.record_admin_local_rental_extension_payment(eid);
    raise exception 'FAIL: unsigned extension activated';
  exception when others then
    if sqlerrm<>'Sign the updated rental agreement before activating this extension.' then raise; end if;
  end;
  if not exists(select 1 from vehicle_availability_blocks where active and notes like '%[EXTENSION_REQUEST='||eid||']%') then
    raise exception 'Rejected activation lost its approved calendar hold.';
  end if;
  update rentals set agreement_signed=true,agreement_signed_at=now(),agreement_signature_name='Synthetic' where id=rid;
  perform public.record_admin_local_rental_extension_payment(eid);
  if exists(select 1 from vehicle_availability_blocks where active and notes like '%[EXTENSION_REQUEST='||eid||']%') then
    raise exception 'Activated extension retained its calendar hold.';
  end if;
  insert into extension_safety_results values('Customer approval honors maintenance; unsigned activation rolls back hold release; signed activation succeeds','passed');

  if public.rentmect_billable_days('2026-11-01','12:00 AM','2026-11-02','12:00 AM')<>1
    or public.rentmect_billable_days('2026-03-08','12:00 AM','2026-03-09','12:00 AM')<>1 then
    raise exception 'DST changed Eastern calendar rental-day billing.';
  end if;
  insert into extension_safety_results values('DST boundaries preserve Eastern calendar rental-day billing','passed');
end; $test$;
set constraints all immediate;
table extension_safety_results;
rollback;
