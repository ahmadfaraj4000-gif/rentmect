\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; cid uuid; receipt uuid; req jsonb; res jsonb; k uuid; i integer; begin
 for i in 1..2 loop
 rid:=pg_temp.account_fixture(300,368.67); -- $445 owed, $300 collateral.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now() where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
 perform sync_rental_remaining_balance(rid,auth.uid());
 select id into strict cid from rental_charge_items where rental_id=rid and source_type='rental_balance' and status='pending';
 if i=2 then
 receipt:=gen_random_uuid();
 perform service_prepare_external_payment(receipt,rid,auth.uid(),jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,'amountCents',5000,'rentalAmountCents',0,'creditAmountCents',5000,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date));
 perform service_finish_external_payment(receipt,auth.uid());
 end if;
 req:=jsonb_build_object('chargeIds',jsonb_build_array(cid),'expectedHeld',300,'expectedCharges',445,'reason','Synthetic partial invoice closeout','includeCredit',i=2,'expectedCreditCents',case when i=2 then 5000 else 0 end);
 k:=gen_random_uuid();
 res:=service_apply_deposit_review(k,rid,auth.uid(),req,(select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
 assert (res->>'remaining')::numeric=0;
 assert (res->>'applied')::numeric=case when i=2 then 350 else 300 end;
 assert rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid)=case when i=2 then 95 else 145 end;
 assert service_apply_deposit_review(k,rid,auth.uid(),req,'[]','[]')=res;
 perform sync_rental_remaining_balance(rid,auth.uid());
 assert rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid)=case when i=2 then 95 else 145 end;
 assert (select sum(amount_held-amount_applied-amount_released)=0 from rental_deposit_allocations where holder_rental_id=rid);
 receipt:=gen_random_uuid();
 perform service_prepare_external_payment(receipt,rid,auth.uid(),jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,'expectedRentalDueCents',case when i=2 then 9500 else 14500 end,'amountCents',case when i=2 then 9500 else 14500 end,'rentalAmountCents',case when i=2 then 9500 else 14500 end,'creditAmountCents',0,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date));
 perform service_finish_external_payment(receipt,auth.uid());
 assert rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid)=0,'Collecting the shortfall did not settle invoice';
 set constraints all immediate; set constraints all deferred;
 end loop;
 raise notice 'PASS partial rental debt, mixed credit, retry and reconciliation';
end $$;
rollback;
