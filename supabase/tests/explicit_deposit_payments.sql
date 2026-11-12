\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql

do $$
declare rid uuid; k uuid:=gen_random_uuid(); k2 uuid:=gen_random_uuid(); k3 uuid:=gen_random_uuid(); req jsonb; req2 jsonb; parts jsonb; result jsonb; aid uuid;
begin
 rid:=pg_temp.account_fixture(300,0);
 parts:=rentmect_payment_due_parts(rid);
 assert parts->>'depositDueCents'='30000' and parts->>'rentalDueCents'='51367';
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,
  'amountCents',15000,'rentalAmountCents',0,'depositAmountCents',15000,'creditAmountCents',0,
  'expectedRentalDueCents',51367,'expectedDepositDueCents',30000,'paymentMethod','cash','receivedDate',current_date-1);
 perform service_prepare_external_payment(k,rid,auth.uid(),req);
 assert not exists(select 1 from rental_deposit_allocations where holder_rental_id=rid);
 result:=service_finish_external_payment(k,auth.uid(),false);
 assert result->>'depositAmountCents'='15000' and result->>'rentalAmountCents'='0';
 perform service_finish_external_payment(k,auth.uid(),false);
 assert (select count(*)=1 and sum(amount_held)=150 and bool_and(payment_provider='local') from rental_deposit_allocations where holder_rental_id=rid);
 parts:=rentmect_payment_due_parts(rid);
 assert parts->>'depositDueCents'='15000' and parts->>'rentalDueCents'='51367',parts::text;
 assert (select deposit_held_amount=150 from rentals where id=rid);
 begin
  perform service_prepare_external_payment(gen_random_uuid(),rid,auth.uid(),req);
  raise exception 'Stale deposit accepted';
 exception when others then if sqlerrm not like '%balance changed%' then raise; end if; end;
 req2:=req||jsonb_build_object('funding','stripe','paymentMethod','card','expectedDepositDueCents',15000);
 perform service_prepare_external_payment(k2,rid,auth.uid(),req2);
 perform service_bind_allocated_stripe(k2,'cs_split_deposit',null,'https://checkout.stripe.com/synthetic');
 assert (select sum(amount_held)=150 from rental_deposit_allocations where holder_rental_id=rid);
 perform service_confirm_allocated_stripe(k2,'cs_split_deposit','pi_split_deposit',15000,'usd',false);
 perform service_confirm_allocated_stripe(k2,'cs_split_deposit','pi_split_deposit',15000,'usd',false);
 assert (select count(*)=2 and sum(amount_held)=300 from rental_deposit_allocations where holder_rental_id=rid);
 assert (select amount_held=150 and payment_provider='stripe' and stripe_payment_intent_id='pi_split_deposit' from rental_deposit_allocations where flex_payment_receipt_id=k2);
 assert (select amount_held=150 and payment_provider='local' and stripe_payment_intent_id is null from rental_deposit_allocations where flex_payment_receipt_id=k);
 parts:=rentmect_payment_due_parts(rid);
 assert parts->>'depositDueCents'='0' and parts->>'rentalDueCents'='51367';
 -- Paying rent later must not create another deposit or change either source.
 req:=req||jsonb_build_object('amountCents',51367,'rentalAmountCents',51367,'depositAmountCents',0,'expectedDepositDueCents',0);
 perform service_prepare_external_payment(k3,rid,auth.uid(),req);
 perform service_finish_external_payment(k3,auth.uid(),false);
 perform ensure_rental_deposit_allocation(rid);
 assert (select count(*)=2 and sum(amount_held)=300 from rental_deposit_allocations where holder_rental_id=rid);
 assert (select payment_status='paid' and deposit_held_amount=300 from rentals where id=rid);
 assert (rentmect_payment_due_parts(rid)->>'bookingDueCents')::integer=0;
 -- Stripe refund updates only its source; external money remains held.
 select id into aid from rental_deposit_allocations where flex_payment_receipt_id=k2;
 perform apply_stripe_deposit_refund(rid,aid,'re_split_deposit','pi_split_deposit','succeeded',150,null);
 assert (select amount_released=0 and amount_held=150 from rental_deposit_allocations where flex_payment_receipt_id=k);
 assert (select deposit_held_amount=150 and deposit_released_amount=150 from rentals where id=rid);
 assert (rentmect_payment_due_parts(rid)->>'depositDueCents')::integer=0;
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert flexible_receipt_refund_block_reason(k) is null;
 assert (admin_flexible_payment_state(rid)->>'depositAllocationsEnabled')::boolean;
 -- A rental-only refund must not return any held external deposit.
 perform admin_refund_external_payment(k3,'Rental payment returned externally','refund-rent-only');
 assert (select amount_released=0 and amount_held=150 from rental_deposit_allocations where flex_payment_receipt_id=k);
 assert (rentmect_payment_due_parts(rid)->>'rentalDueCents')::integer=51367;
 -- Returning the original external deposit receipt affects that source only.
 perform admin_refund_external_payment(k,'External deposit actually returned','refund-deposit');
 assert (select amount_released=150 and external_receipt_refunded_amount=150 from rental_deposit_allocations where flex_payment_receipt_id=k);
 assert (select amount_released=150 and external_receipt_refunded_amount=0 from rental_deposit_allocations where flex_payment_receipt_id=k2);
 raise notice 'PASS: deposit-first, mixed sources, stale amounts, idempotent posting, rent later, source-specific refund and no recollection';
end $$;
rollback;
