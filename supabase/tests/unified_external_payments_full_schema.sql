-- Synthetic fixtures on an isolated copy of the deployed schema only.
-- All business triggers/constraints remain enabled during payment operations.
\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql

do $$
declare
 rid uuid; cid uuid; aid uuid; k uuid;
 req jsonb; result jsonb; posted timestamptz; initial_paid timestamptz; token uuid; deposit_provider text;
begin
 foreach deposit_provider in array array['stripe','local'] loop
 rid:=pg_temp.account_fixture(300,624.67); k:=gen_random_uuid();
 perform set_config('session_replication_role','replica',true);
 update rentals set payment_provider=deposit_provider where id=rid;
 perform set_config('session_replication_role','origin',true);
 select paid_at into initial_paid from rentals where id=rid;
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
 values(rid,rid,deposit_provider,300,'held') returning id into aid;
 perform sync_rental_remaining_balance(rid,auth.uid());
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Synthetic bridge toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('kind','rental_payment','charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',2600)),
 'amountCents',20000,'rentalAmountCents',17400,'expectedRentalDueCents',18900,'paymentMethod','cash_app',
 'receivedDate',current_date-1,'receivedTime','23:00','reference','Synthetic full-schema receipt','notes','Received last night; posted today');
 result:=service_prepare_external_payment(k,rid,auth.uid(),req);
 assert result->>'status'='pending';
 assert admin_rental_detail(rid)->'rental'->>'pending_external_payment_id'=k::text;
 begin
  update rental_charge_items set amount=27,total_amount=27 where id=cid;
  raise exception 'Competing charge change accepted';
 exception when others then if sqlerrm not like '%external payment is being recorded%' then raise; end if; end;
 result:=service_finish_external_payment(k,auth.uid());
 assert (result->>'balanceDue')::numeric=15;
 assert (select sum(amount_cents)=20000 and count(*)=2 from external_payment_allocations where receipt_id=k);
 assert (select payment_status='partially_paid' and deposit_held_amount=300 and paid_at=initial_paid from rentals where id=rid);
 assert (select amount_held=300 and amount_applied=0 and amount_released=0 from rental_deposit_allocations where id=aid);
 assert service_finish_external_payment(k,auth.uid())=result;
 select posted_at into posted from external_payment_receipts where id=k;
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform admin_correct_external_payment(k,current_date-2,'22:30','Corrected reference','Corrected staff note','Synthetic verified correction');
 assert (select posted_at=posted and received_date=current_date-2 from external_payment_receipts where id=k);
 assert (select bool_and(payment_received_date=current_date-2) from rental_charge_items where payment_receipt_id=k);
 assert (select bool_and(c->>'payment_notes'='Corrected staff note') from jsonb_array_elements(admin_rental_detail(rid)->'charges') c where c->>'payment_receipt_id'=k::text);
 perform admin_refund_external_payment(k,'Synthetic full refund','External return confirmed in isolated test');
 perform admin_refund_external_payment(k,'Synthetic full refund retry','External return confirmed in isolated test');
 assert rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid)=189,'Refund must reopen $174 rental debt';
 assert (select external_refunded_amount=26 and status='paid' from rental_charge_items where id=cid),'Original toll cash history must remain';
 assert (select count(*)=1 from rental_charge_items where rental_id=rid and charge_type='toll' and status='pending' and total_amount=26),'Refund must reopen exactly one toll';
 -- Preserve the existing refund classification: externally returned funds may
 -- include the last-funded local deposit portion, but never a Stripe deposit.
 assert (select amount_held=300 and amount_applied=0 and amount_released=case when deposit_provider='local' then 174 else 0 end from rental_deposit_allocations where id=aid),
  'Receipt refund must retain existing deposit-provider rules';
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS full schema: % deposit; $200 allocation, pending recovery, competing-write guard, retry, date correction and existing refund rules',deposit_provider;
 perform set_config('request.jwt.claim.role','service_role',true);
 end loop;

 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(0,0);
 token:=service_reserve_initial_checkout(rid,(select user_id from rentals where id=rid),51367,gen_random_uuid());
 assert service_reserve_initial_checkout(rid,(select user_id from rentals where id=rid),51367,gen_random_uuid())=token;
 perform service_attach_initial_checkout(rid,token,'cs_synthetic_full_schema');
 assert (select checkout_creation_token is null and stripe_checkout_session_id='cs_synthetic_full_schema' from rentals where id=rid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS full schema: initial checkout reservation, retry and attachment';
end $$;
rollback;
