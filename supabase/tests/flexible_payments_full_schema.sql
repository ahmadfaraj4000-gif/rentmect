-- Isolated archived schema, synthetic fixtures, real triggers/constraints/RLS.
\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql

do $$
declare rid uuid; cid uuid; aid uuid; k uuid:=gen_random_uuid(); used uuid:=gen_random_uuid(); req jsonb; result jsonb;
begin
 rid:=pg_temp.account_fixture(300,624.67);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
 values(rid,rid,'stripe',300,'held') returning id into aid;
 perform sync_rental_remaining_balance(rid,auth.uid());
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Synthetic partial toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external',
 'charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1000,'expectedRemainingCents',2600)),
 'amountCents',30000,'rentalAmountCents',17400,'creditAmountCents',11600,'expectedRentalDueCents',18900,
 'paymentMethod','cash_app','receivedDate',(now() at time zone 'America/New_York')::date-1,'receivedTime','23:00','reference','Synthetic','notes','Isolated test');
 result:=service_prepare_external_payment(k,rid,auth.uid(),req);
 result:=service_finish_external_payment(k,auth.uid());
 assert (result->>'balanceDue')::numeric=15;
 assert rental_available_credit_cents(rid)=11600;
 assert (select total_amount=26 and allocated_payment_cents=1000 and status='pending' from rental_charge_items where id=cid);
 assert (select rentmect_charge_remaining_amount(c)=16 from rental_charge_items c where id=cid);
 assert (select amount_held=300 and amount_applied=0 and amount_released=0 from rental_deposit_allocations where id=aid);
 assert service_finish_external_payment(k,auth.uid())=result;
 set constraints all immediate; set constraints all deferred;
 req:=req||jsonb_build_object('funding','credit','amountCents',3100,'rentalAmountCents',1500,'creditAmountCents',0,'expectedRentalDueCents',1500,
 'charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1600,'expectedRemainingCents',1600)));
 perform service_prepare_external_payment(used,rid,auth.uid(),req);
 result:=service_finish_external_payment(used,auth.uid());
 assert rental_available_credit_cents(rid)=8500;
 assert (select total_amount=26 and allocated_payment_cents=2600 and status='paid' from rental_charge_items where id=cid);
 assert (select payment_status='paid' from rentals where id=rid);
 assert (select sum(amount_cents)=30000 from external_payment_receipts where rental_id=rid and funding_kind='external');
 set constraints all immediate; set constraints all deferred;
 perform set_config('request.jwt.claim.role','authenticated',true);
 begin
  perform admin_refund_external_payment(k,'Original credit already spent','test');
  raise exception 'Refund of spent credit was allowed';
 exception when others then if sqlerrm not like '%credit in use%' then raise; end if; end;
 perform admin_refund_external_payment(used,'Reverse synthetic credit application','test');
 assert rental_available_credit_cents(rid)=11600;
 perform admin_refund_external_payment(k,'Synthetic external funds returned','test');
 assert rental_available_credit_cents(rid)=0;
 assert (select total_amount=26 and allocated_payment_cents=0 and status='pending' from rental_charge_items where id=cid);
 assert (select amount_held=300 and amount_applied=0 and amount_released=0 from rental_deposit_allocations where id=aid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS: full-schema overpayment, partial toll, credit reuse/reversal, refund protection, original amounts and Stripe deposit unchanged';

 -- A partially paid charge may settle its exact remainder from the deposit.
 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(300,813.67); k:=gen_random_uuid();
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
 values(rid,rid,'local',300,'held') returning id into aid;
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Mixed deposit toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external',
 'charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1000,'expectedRemainingCents',2600)),
 'amountCents',2000,'rentalAmountCents',0,'creditAmountCents',1000,'expectedRentalDueCents',0,
 'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date-1,'reference','Mixed deposit test','notes','Synthetic');
 perform service_prepare_external_payment(k,rid,auth.uid(),req); perform service_finish_external_payment(k,auth.uid());
 assert (get_rental_account(rid)->>'additional_balance_due')::numeric=16;
 assert rentmect_unpaid_charge_total(rid)=16;
 perform service_deduct_deposit_charges(rid,aid,array[cid],16,284,
  (select jsonb_agg(c) from rental_charge_items c where id=cid),
  (select to_jsonb(a) from rental_deposit_allocations a where id=aid),auth.uid(),'Synthetic deposit settlement',gen_random_uuid());
 assert (select amount_applied=16 from rental_deposit_allocations where id=aid);
 assert (select allocated_payment_cents=1000 and allocated_deposit_cents=1600 and total_amount=26 and status='paid' from rental_charge_items where id=cid);
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform admin_correct_flexible_payment(k,'cash_app',current_date-2,null,'Verified','Corrected synthetic note','Verified synthetic receipt');
 assert (select payment_method='cash_app' and credit_amount_cents=1000 from external_payment_receipts where id=k);
 perform admin_refund_external_payment(k,'Returned synthetic external funds','test');
 assert (select rentmect_charge_remaining_amount(c)=10 from rental_charge_items c where id=cid);
 assert (select allocated_payment_cents=0 and allocated_deposit_cents=1600 and total_amount=26 from rental_charge_items where id=cid);
 assert (select amount_applied=16 from rental_deposit_allocations where id=aid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS: partial-charge deposit settlement, metadata correction and external refund preserve the deposit application';
 perform set_config('request.jwt.claim.role','service_role',true);
 update rental_charge_items set checkout_creation_token=gen_random_uuid() where id=cid;
 update rental_charge_items set checkout_creation_token=null,status='checkout_open',stripe_checkout_session_id='cs_synthetic_deposit_remainder',payment_amount_cents=1000 where id=cid;
 perform record_stripe_rental_charge_payment(cid,'cs_synthetic_deposit_remainder','pi_synthetic_deposit_remainder',1000,'usd');
 perform record_stripe_rental_charge_payment(cid,'cs_synthetic_deposit_remainder','pi_synthetic_deposit_remainder',1000,'usd');
 assert (select allocated_payment_cents=1000 and allocated_deposit_cents=1600 and status='paid' and total_amount=26 from rental_charge_items where id=cid);
 assert (select amount_applied=16 from rental_deposit_allocations where id=aid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS: mixed deposit remainder paid by Stripe without replacing deposit evidence';


 -- Full initial receipt preserves a distinct deposit source and unapplied money.
 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(300,0); k:=gen_random_uuid();
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,
 'amountCents',90000,'rentalAmountCents',81367,'creditAmountCents',8633,'expectedRentalDueCents',81367,
 'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date-1);
 perform service_prepare_external_payment(k,rid,auth.uid(),req);
 result:=service_finish_external_payment(k,auth.uid());
 assert (result->>'balanceDue')::numeric=0;
 assert rental_available_credit_cents(rid)=8633;
 assert (select sum(amount_held)=300 and bool_and(flex_payment_receipt_id=k) from rental_deposit_allocations where holder_rental_id=rid);
 assert (select sum(amount_cents)=81367 from external_payment_allocations where receipt_id=k);
 set constraints all immediate; set constraints all deferred;
 -- Once a deposit has paid another charge, the full rental receipt cannot also
 -- be returned. The same reason is visible before staff confirm a cash refund.
 select id into aid from rental_deposit_allocations where holder_rental_id=rid;
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Deposit reconciliation toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 perform service_deduct_deposit_charges(rid,aid,array[cid],26,274,
  (select jsonb_agg(c) from rental_charge_items c where id=cid),
  (select to_jsonb(a) from rental_deposit_allocations a where id=aid),auth.uid(),'Synthetic deposit use',gen_random_uuid());
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert flexible_receipt_refund_block_reason(k) like '%deposit reconciliation%';
 assert (admin_flexible_payment_state(rid)->'receipts'->0->>'refund_block_reason') like '%deposit reconciliation%';
 begin
  perform admin_refund_external_payment(k,'Attempt duplicate deposit return','test');
  raise exception 'Used deposit full refund was allowed';
 exception when others then if sqlerrm not like '%deposit reconciliation%' then raise; end if; end;
 assert (select status='posted' from external_payment_receipts where id=k);
 assert (select amount_applied=26 and amount_released=0 from rental_deposit_allocations where id=aid);
 assert rental_available_credit_cents(rid)=8633;
 set constraints all immediate; set constraints all deferred;
 -- Customer identities cannot access the staff receipt state or post funds.
 perform set_config('request.jwt.claim.sub',(select user_id::text from rentals where id=rid),true);
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert (get_rental_account(rid)->>'available_customer_credit')::numeric=86.33;
 assert not (get_rental_account(rid) ? 'receipts');
 begin
  perform admin_flexible_payment_state(rid); raise exception 'Customer read was allowed';
 exception when others then if sqlerrm not like '%Payment access required%' then raise; end if; end;
 begin
  perform service_finish_external_payment(k,auth.uid()); raise exception 'Customer posting was allowed';
 exception when others then if sqlerrm not like '%Service role required%' then raise; end if; end;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin
  perform get_rental_account(rid); raise exception 'Other customer account read was allowed';
 exception when others then if sqlerrm not like '%Rental not found%' then raise; end if; end;
 perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
 raise notice 'PASS: initial receipt, separate held deposit, unused credit, customer permission denial';

 -- Reversing credit that funded a deposit must never manufacture a cash refund.
 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(300,0); k:=gen_random_uuid(); used:=gen_random_uuid();
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,
  'amountCents',90000,'rentalAmountCents',0,'creditAmountCents',90000,'expectedRentalDueCents',81367,
  'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date-1);
 perform service_prepare_external_payment(k,rid,auth.uid(),req); perform service_finish_external_payment(k,auth.uid());
 req:=req||jsonb_build_object('funding','credit','amountCents',81367,'rentalAmountCents',81367,'creditAmountCents',0);
 perform service_prepare_external_payment(used,rid,auth.uid(),req); perform service_finish_external_payment(used,auth.uid());
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert flexible_receipt_refund_block_reason(used) like '%credit application funds a held deposit%';
 begin
  perform admin_refund_external_payment(used,'Reverse synthetic deposit credit','test');
  raise exception 'Credit deposit reversal was recorded as cash';
 exception when others then if sqlerrm not like '%credit application funds a held deposit%' then raise; end if; end;
 assert (select status='posted' from external_payment_receipts where id=used);
 assert rental_available_credit_cents(rid)=8633;
 assert (select sum(amount_held)=300 and sum(amount_released)=0 and sum(external_receipt_refunded_amount)=0 from rental_deposit_allocations where holder_rental_id=rid);
 assert not exists(select 1 from rental_external_payment_actions where rental_id=rid and action_type='refund');
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS: used deposit blocks duplicate receipt refund; credit deposit reversal cannot fabricate cash returned';
 -- Existing checkout must collect the remainder and webhook replay must be inert.
 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(300,813.67); k:=gen_random_uuid();
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Stripe remainder toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1000,'expectedRemainingCents',2600)),
 'amountCents',1000,'rentalAmountCents',0,'creditAmountCents',0,'expectedRentalDueCents',0,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date-1);
 perform service_prepare_external_payment(k,rid,auth.uid(),req);perform service_finish_external_payment(k,auth.uid());
 update rental_charge_items set checkout_creation_token=gen_random_uuid() where id=cid;
 update rental_charge_items set checkout_creation_token=null,status='checkout_open',payment_provider='stripe',stripe_checkout_session_id='cs_synthetic_remainder',payment_amount_cents=1600 where id=cid;
 begin
  perform record_stripe_rental_charge_payment(cid,'cs_synthetic_remainder','pi_synthetic_remainder',2600,'usd');raise exception 'Original charge amount was accepted after partial payment';
 exception when others then if sqlerrm not like '%remaining allocated charge balance%' then raise; end if; end;
 perform record_stripe_rental_charge_payment(cid,'cs_synthetic_remainder','pi_synthetic_remainder',1600,'usd');
 perform record_stripe_rental_charge_payment(cid,'cs_synthetic_remainder','pi_synthetic_remainder',1600,'usd');
 assert (select total_amount=26 and allocated_payment_cents=2600 and status='paid' from rental_charge_items where id=cid);
 assert (select count(*)=1 and sum(amount_cents)=1600 from external_payment_receipts where stripe_payment_intent_id='pi_synthetic_remainder');
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform admin_refund_external_payment(k,'Return only the cash portion','synthetic');
 assert (select allocated_payment_cents=1600 and rentmect_charge_remaining_amount(c)=10 from rental_charge_items c where id=cid);
 perform set_config('request.jwt.claim.role','service_role',true);
 perform record_stripe_rental_charge_payment(cid,'cs_synthetic_remainder','pi_synthetic_remainder',1600,'usd');
 assert (select allocated_payment_cents=1600 and rentmect_charge_remaining_amount(c)=10 from rental_charge_items c where id=cid);
 set constraints all immediate;set constraints all deferred;
 raise notice 'PASS: partial external receipt, Stripe remainder, original-price rejection, duplicate webhook and external-only refund';
 update rental_charge_items set admin_charge_attempted_at=now() where id=cid;
 k:=gen_random_uuid();
 req:=req||jsonb_build_object('charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1000,'expectedRemainingCents',1000)));
 result:=service_prepare_external_payment(k,rid,auth.uid(),req);
 assert not ((result->'charges'->0) ? 'stripe_payment_intent_id');
 assert not ((result->'charges'->0) ? 'stripe_checkout_session_id');
 perform service_finish_external_payment(k,auth.uid());
 assert (select allocated_payment_cents=2600 and status='paid' from rental_charge_items where id=cid);
 set constraints all immediate;set constraints all deferred;
 assert (select admin_charge_attempted_at is null from rental_charge_items where id=cid);
 raise notice 'PASS: recollect refunded external portion without retiring already posted Stripe funds';



 -- A single verified Stripe payment can cover rent, extras, and future credit.
 perform set_config('request.jwt.claim.role','service_role',true);
 rid:=pg_temp.account_fixture(300,0);k:=gen_random_uuid();
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Allocated Stripe toll','toll',26,false,26,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','stripe','charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',1000,'expectedRemainingCents',2600)),
 'amountCents',90000,'rentalAmountCents',81367,'creditAmountCents',7633,'expectedRentalDueCents',81367,'paymentMethod','card','receivedDate',(now() at time zone 'America/New_York')::date-1);
 perform service_prepare_external_payment(k,rid,auth.uid(),req);
 begin perform service_finish_external_payment(k,auth.uid());raise exception 'Unconfirmed Stripe posted';
 exception when others then if sqlerrm not like '%Provider confirmation%' then raise;end if;end;
 perform service_bind_allocated_stripe(k,'cs_allocated_test',null,'https://checkout.stripe.com/test');
 begin perform service_confirm_allocated_stripe(k,'cs_wrong','pi_allocated_test',90000,'usd');raise exception 'Wrong session posted';
 exception when others then if sqlerrm not like '%reservation%' then raise;end if;end;
 begin perform service_confirm_allocated_stripe(k,'cs_allocated_test','pi_allocated_test',89999,'usd');raise exception 'Wrong amount posted';
 exception when others then if sqlerrm not like '%amount and currency%' then raise;end if;end;
 perform service_confirm_allocated_stripe(k,'cs_allocated_test','pi_allocated_test',90000,'usd');
 perform service_confirm_allocated_stripe(k,'cs_allocated_test','pi_allocated_test',90000,'usd');
 assert (select allocated_payment_cents=1000 and total_amount=26 and status='pending' from rental_charge_items where id=cid);
 assert rental_available_credit_cents(rid)=7633;
 assert (select sum(amount_held)=300 and bool_and(payment_provider='stripe') and bool_and(stripe_payment_intent_id='pi_allocated_test') from rental_deposit_allocations where holder_rental_id=rid);
 assert rentmect_rental_net_paid_amount(rid)=813.67;
 assert (select count(*)=1 from external_payment_receipts where stripe_payment_intent_id='pi_allocated_test');
 assert (select received_date=(now() at time zone 'America/New_York')::date and received_time is not null from external_payment_receipts where id=k);
 set constraints all immediate;set constraints all deferred;
 raise notice 'PASS: allocated Stripe rent + partial toll + excess credit, deposit source, amount validation and webhook replay';

end $$;
rollback;
