-- Synthetic rollback-only tests. Run against a disposable full-schema fixture.
\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

do $$
declare rid uuid; q jsonb; result jsonb; original_start date; key uuid:=gen_random_uuid(); old_amount numeric;
begin
 rid:=pg_temp.account_fixture(300,813.67);
 select pickup_date into original_start from public.rentals where id=rid;
 q:=public.admin_rental_change_context(rid);
 assert (q->>'daily_rate')::numeric=69, 'Saved daily rate missing';
 q:=public.admin_preview_rental_extension(rid,current_date+5,'9:00 AM',69,'Customer agreed to five days');
 perform public.admin_apply_rental_extension(rid,current_date+5,'9:00 AM',69,'Customer agreed to five days',gen_random_uuid(),q->>'revision');
 q:=public.admin_rental_change_context(rid);
 assert q->'revisable_extension' is not null;
 q:=public.admin_preview_rental_extension_revision(rid,current_date+4,'9:00 AM',69,'Customer can afford four days');
 assert (q->>'extension_days')::integer=4;
 assert (q->>'total_delta')::numeric=-73.38, 'One day and its tax should be removed';
 result:=public.admin_apply_rental_extension_revision(rid,current_date+4,'9:00 AM',69,'Customer can afford four days',key,q->>'revision');
 assert (select pickup_date=original_start and return_date=current_date+4 and deposit_held_amount=300 and not agreement_signed from public.rentals where id=rid);
 assert (select count(*)=1 from public.rental_admin_extensions where rental_id=rid), 'Original extension history lost';
 result:=public.admin_apply_rental_extension_revision(rid,current_date+4,'9:00 AM',69,'Customer can afford four days',key,'stale');
 assert (result->>'idempotent_replay')::boolean;
 begin
  perform public.admin_apply_rental_extension_revision(rid,current_date+3,'9:00 AM',69,'Customer can afford three days',gen_random_uuid(),q->>'revision');
  raise exception 'Stale revision accepted';
 exception when others then if SQLERRM not like '%Review the revision again%' then raise; end if; end;
 set constraints all immediate;
 set constraints all deferred;
 raise notice 'PASS five-day extension revised to four; price, history, agreement, stale checks and retry';
end $$;

do $$
declare rid uuid; aid uuid; cid uuid; cid2 uuid; key uuid; result jsonb; snapshot jsonb; provider text;
begin
 foreach provider in array array['local','stripe'] loop
  rid:=pg_temp.account_fixture(300,813.67); key:=gen_random_uuid();
  insert into public.rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,stripe_payment_intent_id,amount_held,status)
   select id,id,provider,case when provider='stripe' then 'pi_synthetic_'||id::text else null end,300,'held' from public.rentals where id=rid returning id into aid;
  insert into public.rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount)
   select id,user_id,'Synthetic fuel','fuel',50,false,50 from public.rentals where id=rid returning id into cid;
  select jsonb_agg(to_jsonb(c)) into snapshot from public.rental_charge_items c where id=cid;
  perform set_config('request.jwt.claim.role','service_role',true);
  begin
   perform public.service_deduct_deposit_charges(rid,aid,array[cid],50,249,snapshot,(select to_jsonb(a) from public.rental_deposit_allocations a where id=aid),auth.uid(),'Customer deposit deduction',key);
   raise exception 'Stale deposit accepted';
  exception when others then if SQLERRM not like '%amounts changed%' then raise; end if; end;
  result:=public.service_deduct_deposit_charges(rid,aid,array[cid],50,250,snapshot,(select to_jsonb(a) from public.rental_deposit_allocations a where id=aid),auth.uid(),'Customer deposit deduction',key);
  assert (result->>'remaining')::numeric=250;
  assert (select deposit_held_amount=250 and deposit_released_amount=0 from public.rentals where id=rid);
  assert (select status='paid' and payment_provider='deposit' and payment_amount_cents=0 from public.rental_charge_items where id=cid);
  result:=public.service_deduct_deposit_charges(rid,aid,array[cid],50,250,'[]',null,auth.uid(),'Customer deposit deduction',key);
  assert (result->>'duplicate')::boolean;
  begin
   update public.rental_charge_items set status='pending' where id=cid;
   raise exception 'Double collection allowed';
  exception when others then if SQLERRM not like '%cannot be collected%' then raise; end if; end;
  -- Staff can still extend an active rental after an add-on deduction.
  perform set_config('request.jwt.claim.role','authenticated',true);
  result:=public.admin_preview_rental_extension(rid,current_date+4,'9:00 AM',69,'Extension after deposit charge');
  perform public.admin_apply_rental_extension(rid,current_date+4,'9:00 AM',69,'Extension after deposit charge',gen_random_uuid(),result->>'revision');
  set constraints all immediate; set constraints all deferred;
  -- Return fixture: preserve the allocation; mark the rental inspected and paid
  -- without performing unrelated real-world return/payment procedures.
  perform set_config('session_replication_role','replica',true);
  update public.rentals set status='completed',inspection_completed_at=now(),rental_total=483,tax_amount=30.67 where id=rid;
  delete from public.rental_pricing_periods where rental_id=rid;
  delete from public.rental_charge_items where rental_id=rid and charge_type='rental_amendment';
  perform set_config('session_replication_role','origin',true);
  if provider='local' then
   perform public.admin_record_local_deposit_release(rid);
  else
   perform set_config('request.jwt.claim.role','service_role',true);
   perform public.service_reserve_deposit_refunds(rid);
   perform public.apply_stripe_deposit_refund(rid,aid,'re_synthetic_'||aid::text,'pi_synthetic_'||rid::text,'succeeded',250);
  end if;
  assert (select amount_applied=50 and amount_released=250 and status='released' from public.rental_deposit_allocations where id=aid);
  assert (select deposit_held_amount=0 and deposit_released_amount=250 from public.rentals where id=rid);
  perform set_config('request.jwt.claim.role','service_role',true);
  result:=public.service_deduct_deposit_charges(rid,aid,array[cid],50,250,'[]',null,auth.uid(),'Customer deposit deduction',key);
  assert (result->>'duplicate')::boolean, 'Retry after refund must not deduct again';
  set constraints all immediate; set constraints all deferred;
  raise notice 'PASS % deposit: active deduction, extension afterward, remainder-only refund, retry after refund',provider;
 end loop;
end $$;
do $$
declare rid uuid; aid uuid; cid uuid; other uuid; snap jsonb; q jsonb; result jsonb; k uuid:=gen_random_uuid();
begin
 rid:=pg_temp.account_fixture(300,813.67);
 insert into public.rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
  values(rid,rid,'local',300,'held') returning id into aid;
 insert into public.rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount)
  select id,user_id,'Synthetic damage','damage',300,false,300 from public.rentals where id=rid returning id into cid;
 select jsonb_agg(to_jsonb(c)) into snap from public.rental_charge_items c where id=cid;
 perform set_config('request.jwt.claim.role','authenticated',true);
 begin
  perform public.service_deduct_deposit_charges(rid,aid,array[cid],300,0,snap,(select to_jsonb(a) from public.rental_deposit_allocations a where id=aid),auth.uid(),'Entire deposit applied',k);
  raise exception 'Customer role accepted';
 exception when others then if SQLERRM not like '%Service role required%' then raise; end if; end;
 perform set_config('request.jwt.claim.role','service_role',true);
 -- Simulate another collector claiming the charge after Edge checked it.
 update public.rental_charge_items set admin_charge_attempts=1 where id=cid;
 begin
  perform public.service_deduct_deposit_charges(rid,aid,array[cid],300,0,snap,(select to_jsonb(a) from public.rental_deposit_allocations a where id=aid),auth.uid(),'Entire deposit applied',k);
  raise exception 'Concurrent attempt accepted';
 exception when others then if SQLERRM not like '%payment attempt changed%' then raise; end if; end;
 select jsonb_agg(to_jsonb(c)) into snap from public.rental_charge_items c where id=cid;
 result:=public.service_deduct_deposit_charges(rid,aid,array[cid],300,0,snap,(select to_jsonb(a) from public.rental_deposit_allocations a where id=aid),auth.uid(),'Entire deposit applied',k);
 assert (select amount_applied=300 and amount_released=0 and refund_completed_at is null from public.rental_deposit_allocations where id=aid);
 assert (select deposit_held_amount=0 and deposit_released_amount=0 from public.rentals where id=rid);
 perform public.ensure_rental_deposit_allocation(rid);
 assert (select count(*)=1 from public.rental_deposit_allocations where holder_rental_id=rid), 'Fully applied deposit was recreated';
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS full deposit used without fake refund, permission and concurrent payment guards';

 perform set_config('request.jwt.claim.role','authenticated',true);
 rid:=pg_temp.account_fixture(300,1200);
 q:=public.admin_preview_rental_extension(rid,current_date+2,'9:00 AM',69,'First agreed extension');
 perform public.admin_apply_rental_extension(rid,current_date+2,'9:00 AM',69,'First agreed extension',gen_random_uuid(),q->>'revision');
 q:=public.admin_preview_rental_extension(rid,current_date+7,'9:00 AM',69,'Second agreed extension');
 perform public.admin_apply_rental_extension(rid,current_date+7,'9:00 AM',69,'Second agreed extension',gen_random_uuid(),q->>'revision');
 q:=public.admin_preview_rental_extension_revision(rid,current_date+2,'9:00 AM',69,'Cancel unneeded second extension');
 assert (q->>'extension_days')::integer=0;
 assert (q->>'credit_due')::numeric>0;
 perform public.admin_apply_rental_extension_revision(rid,current_date+2,'9:00 AM',69,'Cancel unneeded second extension',gen_random_uuid(),q->>'revision');
 assert (select count(*)=2 from public.rental_pricing_periods where rental_id=rid);
 assert (select return_date=current_date+2 and payment_amount_cents=120000 from public.rentals where id=rid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS remove entire future extension, preserve prior extension and paid receipts, expose credit';
end $$;
rollback;
