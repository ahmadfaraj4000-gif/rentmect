\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; k uuid:=gen_random_uuid(); req jsonb; parts jsonb; result jsonb; begin
 rid:=pg_temp.account_fixture(400,0);
 req:=jsonb_build_object('kind','rental_payment','charges','[]'::jsonb,'amountCents',27000,'rentalAmountCents',27000,
  'expectedRentalDueCents',91367,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date-1,'receivedTime','','reference','','notes','');
 perform service_prepare_external_payment(k,rid,auth.uid(),req);
 perform service_finish_external_payment(k,auth.uid(),false);
 result:=service_reclassify_legacy_deposit(k,27000,'Owner requested deposit-first classification of original receipt.');
 assert result->>'depositAmountCents'='27000' and result->>'rentalAmountCents'='0';
 perform service_reclassify_legacy_deposit(k,27000,'Retry same reconciliation safely.');
 assert (select count(*)=1 and sum(amount_held)=270 from rental_deposit_allocations where holder_rental_id=rid);
 parts:=rentmect_payment_due_parts(rid);
 assert parts->>'depositDueCents'='13000' and parts->>'rentalDueCents'='51367',parts::text;
 assert (select count(*)=1 from rental_audit_events where rental_id=rid and event_type='legacy_receipt_deposit_reclassified');
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','charges','[]'::jsonb,'allocationPriority','deposit_first',
  'amountCents',10000,'rentalAmountCents',10000,'depositAmountCents',0,'creditAmountCents',0,'expectedRentalDueCents',51367,
  'expectedDepositDueCents',13000,'paymentMethod','cash','receivedDate',(now() at time zone 'America/New_York')::date);
 begin
  perform service_prepare_external_payment(gen_random_uuid(),rid,auth.uid(),req);
  raise exception 'Rental-first payment accepted';
 exception when others then if sqlerrm not like '%Fund the security deposit%' then raise; end if; end;
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert flexible_receipt_refund_block_reason(k) is null;
 perform admin_refund_external_payment(k,'Customer received the original external payment back','synthetic-refund');
 assert (select amount_released=270 and external_receipt_refunded_amount=270 from rental_deposit_allocations where flex_payment_receipt_id=k);
 assert rentmect_rental_net_paid_amount(rid)=0;
 parts:=rentmect_payment_due_parts(rid);
 assert parts->>'depositDueCents'='40000' and parts->>'rentalDueCents'='51367',parts::text;
 raise notice 'PASS: deposit-first classification, unchanged balance, idempotent reconciliation, priority guard and source refund';
end $$;
rollback;
