\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$
declare rid uuid; cid uuid; k uuid; receipt uuid; req jsonb; res jsonb; i integer; charge numeric;
begin
 for i in 1..4 loop
  rid:=pg_temp.account_fixture(300,813.67);receipt:=gen_random_uuid();k:=gen_random_uuid();charge:=case i when 1 then 80 when 2 then 325 when 3 then 400 else 80 end;
  insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
  req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,'amountCents',5000,'rentalAmountCents',0,'creditAmountCents',5000,'paymentMethod','cash_app','receivedDate',(now() at time zone 'America/New_York')::date,'notes','Synthetic credit');
  perform service_prepare_external_payment(receipt,rid,auth.uid(),req);
  perform service_finish_external_payment(receipt,auth.uid());
  if i=4 then
   update external_payment_receipts set funding_kind='stripe',stripe_payment_intent_id='pi_synthetic_credit' where id=receipt;
   update rental_deposit_allocations set amount_held=200 where holder_rental_id=rid;
   insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status,stripe_payment_intent_id) values(rid,rid,'stripe',100,'held','pi_synthetic_deposit');
  end if;
  perform set_config('session_replication_role','replica',true);
  update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now() where id=rid;
  perform set_config('session_replication_role','origin',true);
  insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type) select rid,user_id,'Synthetic cleaning','cleaning',charge,false,charge,'manual' from rentals where id=rid returning id into cid;
  req:=jsonb_build_object('chargeIds',jsonb_build_array(cid),'expectedHeld',300,'expectedCharges',charge,'reason','Synthetic return reviewed','includeCredit',true,'expectedCreditCents',5000);
  res:=service_apply_deposit_review(k,rid,auth.uid(),req,(select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
  assert (res->>'remaining')::numeric=greatest(0,350-charge);
  assert (res->>'applied')::numeric=least(350,charge);
  assert rental_available_credit_cents(rid)=0;
  assert (select applied_cents=least(5000,greatest(0,charge-300)*100) and refund_cents=greatest(0,350-greatest(charge,300))*100 from rental_return_credit_sources where review_id=k);
  assert (select rentmect_charge_remaining_amount(c)=greatest(0,charge-350) from rental_charge_items c where id=cid);
  assert service_apply_deposit_review(k,rid,auth.uid(),req,'[]','[]')=res;
  if i<3 then
   begin
    perform service_record_return_external(k,auth.uid(),'Cash App','synthetic',99999);
    raise exception 'Stale external amount accepted';
   exception when others then if sqlerrm not like '%amount changed%' then raise; end if; end;
   perform service_record_return_external(k,auth.uid(),'Cash App','synthetic',round((350-charge)*100)::bigint);
   perform service_record_return_external(k,auth.uid(),'Cash App','synthetic',round((350-charge)*100)::bigint);
   assert (select status='succeeded' and payout_method='Cash App' from rental_return_credit_sources where review_id=k);
   assert (select sum(amount_held-amount_applied-amount_released)=0 from rental_deposit_allocations where holder_rental_id=rid);
   perform set_config('request.jwt.claim.role','authenticated',true);
   assert jsonb_array_length(admin_flexible_payment_state(rid)->'creditReturns')=1;
   assert exists(select 1 from jsonb_array_elements(admin_payment_activity_page('refunds','refund',0)->'rows') x where x->>'id'='return-credit-'||k::text||'-'||receipt::text and (x->>'cashImpact')::numeric=-(case when i=1 then 50 else 25 end));
   perform set_config('request.jwt.claim.role','service_role',true);
  end if;
  begin
   insert into rental_payment_refunds(id,rental_id,stripe_payment_intent_id,amount,reason) values(gen_random_uuid(),rid,'pi_old_tab',10,'Synthetic conflicting refund');
   raise exception 'Competing refund reservation accepted';
  exception when others then if sqlerrm not like '%saved deposit and credit return%' then raise; end if; end;
  begin
   update external_payment_receipts set status='refunded' where id=receipt;
   raise exception 'Source refund was not protected';
  exception when others then if sqlerrm not like '%return settlement%' then raise; end if; end;
 end loop;
 raise notice 'PASS: deposit + credit minus charges, partial charges, source reservation and retry';
end $$;
set constraints all immediate;
rollback;
