\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; cid uuid; k uuid; req jsonb; res jsonb; i integer; receipt uuid; attempt uuid; begin
 for i in 1..3 loop
 rid:=pg_temp.account_fixture(300,709.44); -- $813.67 invoice: $104.23 remains.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now() where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
 perform sync_rental_remaining_balance(rid,auth.uid());
 select id into strict cid from rental_charge_items where rental_id=rid and source_type='rental_balance' and status='pending';
 if i=2 then update rental_charge_items set source_type='rental_amendment' where id=cid; end if;
 if i=3 then
  update rental_deposit_allocations set amount_held=75 where holder_rental_id=rid;
  receipt:=gen_random_uuid();
  perform service_prepare_external_payment(receipt,rid,auth.uid(),jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,'amountCents',5000,'rentalAmountCents',0,'creditAmountCents',5000,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date));
  perform service_finish_external_payment(receipt,auth.uid());
 end if;
 assert exists(select 1 from jsonb_array_elements(admin_return_workspace(rid)->'charges') x where x->>'id'=cid::text),'Rental debt absent from workspace';
 if i=2 then
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount) select rid,user_id,'Cleaning','cleaning',20,20 from rentals where id=rid;
 end if;
 req:=jsonb_build_object('chargeIds',(select jsonb_agg(id) from rental_charge_items where rental_id=rid and status='pending'),'expectedHeld',case when i=3 then 75 else 300 end,'expectedCharges',case when i=2 then 124.23 else 104.23 end,'includeCredit',i=3,'expectedCreditCents',case when i=3 then 5000 else 0 end,'reason','Synthetic rental balance return');
 if i=1 then
  update rental_charge_items set amount=104.22,total_amount=104.22 where id=cid;
  begin
   perform service_apply_deposit_review(gen_random_uuid(),rid,auth.uid(),req||jsonb_build_object('expectedCharges',104.22),(select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
   raise exception 'Stale invoice accepted';
  exception when others then if sqlerrm not like '%Rental balance changed%' then raise; end if; end;
  update rental_charge_items set amount=104.23,total_amount=104.23 where id=cid;
  insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount) select rid,user_id,'Open attempt','rental_installment',104.23,104.23 from rentals where id=rid returning id into attempt;
  begin
   perform service_apply_deposit_review(gen_random_uuid(),rid,auth.uid(),req,(select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
   raise exception 'Concurrent collection accepted';
  exception when others then if sqlerrm not like '%other rental payment attempts%' then raise; end if; end;
  update rental_charge_items set status='waived' where id=attempt;
 end if;
 k:=gen_random_uuid();
 res:=service_apply_deposit_review(k,rid,auth.uid(),req,(select jsonb_agg(c) from rental_charge_items c where rental_id=rid and status='pending'),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
 assert (res->>'remaining')::numeric=case when i=1 then 195.77 when i=2 then 175.77 else 20.77 end;
 assert rentmect_rental_net_paid_amount(rid)=813.67,'Rental debt was not settled exactly once';
 assert (select payment_amount_cents=70944 from rentals where id=rid),'Collateral was counted as new cash';
 assert service_apply_deposit_review(k,rid,auth.uid(),req,'[]','[]')=res,'Retry changed settlement';
 assert rentmect_rental_net_paid_amount(rid)=813.67;
 perform service_record_return_external(k,auth.uid(),'Cash','synthetic',case when i=1 then 19577 when i=2 then 17577 else 2077 end);
 assert (select sum(amount_held-amount_applied-amount_released)=0 from rental_deposit_allocations where holder_rental_id=rid);
 set constraints all immediate; set constraints all deferred;
 end loop;
 raise notice 'PASS rental debt deduction, combined charges, exact external remainder and retry';
end $$;
rollback;
