\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$
declare rid uuid; cid uuid; key uuid; receipt uuid; req jsonb; preview jsonb; result jsonb;
begin
 rid:=pg_temp.account_fixture(300,0);
 result:=record_admin_rental_balance_payment(rid,813.67,'cash','Synthetic receipt',auth.uid());
 cid:=(result->'payment'->>'id')::uuid;key:=gen_random_uuid();
 perform set_config('request.jwt.claim.role','authenticated',true);
 req:=jsonb_build_object('expectedAmountCents',81367,'amountCents',70000,'paymentMethod','cash','receivedDate',current_date-1,'reason','Correct transcribed cash amount','reference','test','notes','synthetic');
 preview:=admin_correct_payment_amount('rental_charge',cid,req,key);
 assert preview->>'status'='review';assert (select payment_amount_cents=81367 from rental_charge_items where id=cid);
 result:=admin_correct_payment_amount('rental_charge',cid,req,key,preview->>'reviewToken');
 assert result->>'status'='corrected';assert rentmect_rental_net_paid_amount(rid)=700;
 assert (select sum(amount_held)=300 from rental_deposit_allocations where holder_rental_id=rid);
 assert (get_rental_account(rid)->>'balance_due')::numeric=113.67;
 assert admin_correct_payment_amount('rental_charge',cid,req,key,preview->>'reviewToken')=result;
 assert (select count(*)=1 from payment_amount_corrections where id=key);
 set constraints all immediate;set constraints all deferred;
 -- An additional charge retains its original invoice; a correction can reopen a partial balance.
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type,status,payment_provider,payment_amount_cents,paid_at,external_payment_method)
 select rid,user_id,'Transport','manual',63.81,false,63.81,'manual','paid','local',6381,now(),'cash' from rentals where id=rid returning id into cid;
 req:=req||jsonb_build_object('expectedAmountCents',6381,'amountCents',4000);key:=gen_random_uuid();
 preview:=admin_correct_payment_amount('rental_charge',cid,req,key);
 result:=admin_correct_payment_amount('rental_charge',cid,req,key,preview->>'reviewToken');receipt:=(result->>'receiptId')::uuid;
 assert (select total_amount=63.81 and allocated_payment_cents=4000 and status='pending' from rental_charge_items where id=cid);
 assert (select amount_cents=4000 from external_payment_receipts where id=receipt);
 set constraints all immediate;set constraints all deferred;
 -- More received money is retained as credit, and a later decrease removes credit before reopening allocations.
 req:=req||jsonb_build_object('expectedAmountCents',4000,'amountCents',9000);key:=gen_random_uuid();
 preview:=admin_correct_payment_amount('receipt',receipt,req,key);
 result:=admin_correct_payment_amount('receipt',receipt,req,key,preview->>'reviewToken');
 assert rental_available_credit_cents(rid)=5000;
 assert (select allocated_payment_cents=4000 from rental_charge_items where id=cid);
 req:=req||jsonb_build_object('expectedAmountCents',9000,'amountCents',3000);key:=gen_random_uuid();
 preview:=admin_correct_payment_amount('receipt',receipt,req,key);
 result:=admin_correct_payment_amount('receipt',receipt,req,key,preview->>'reviewToken');
 assert rental_available_credit_cents(rid)=0;
 assert (select allocated_payment_cents=3000 and total_amount=63.81 from rental_charge_items where id=cid);
 assert (select amount_cents=3000 from external_payment_allocations where receipt_id=receipt);
 set constraints all immediate;set constraints all deferred;
 -- A stale review and mismatched amount must not change the ledger.
 req:=req||jsonb_build_object('expectedAmountCents',3000,'amountCents',3100);key:=gen_random_uuid();
 preview:=admin_correct_payment_amount('receipt',receipt,req,key);
 perform admin_correct_flexible_payment(receipt,'cash',current_date-1,null,'Updated reference','','Synthetic concurrent metadata edit');
 begin
  perform admin_correct_payment_amount('receipt',receipt,req,key,preview->>'reviewToken');
  raise exception 'Stale confirmation accepted';
 exception when others then if sqlerrm not like '%changed after review%' then raise;end if;end;
 assert (select amount_cents=3000 from external_payment_receipts where id=receipt);
 begin
  perform admin_correct_payment_amount('receipt',receipt,req||jsonb_build_object('expectedAmountCents',2999),gen_random_uuid());
  raise exception 'Wrong amount accepted';
 exception when others then if sqlerrm not like '%payment changed%' then raise;end if;end;
 perform set_config('request.jwt.claim.sub',(select user_id::text from rentals where id=rid),true);
 begin
  perform admin_correct_payment_amount('receipt',receipt,req,gen_random_uuid());
  raise exception 'Customer corrected payment';
 exception when others then if sqlerrm not like '%Staff access%' then raise;end if;end;
 perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
 raise notice 'PASS: correction preview, confirmation, idempotency, original invoices, deposit preservation, partial charges and credit reductions';
end $$;
rollback;
