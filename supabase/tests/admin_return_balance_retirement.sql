\set ON_ERROR_STOP on
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; uid uuid; begin
 rid:=pg_temp.account_fixture();select user_id into uid from rentals where id=rid;
 perform set_config('session_replication_role','replica',true);
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,tax_amount,total_amount,status,source_type,source_reference,allocation_managed,allocated_payment_cents)
 values(rid,uid,'Synthetic unpaid auto fee','late_fee',25,false,0,25,'pending','late_return','policy-test-unpaid',false,0),
 (rid,uid,'Synthetic partial auto fee','late_fee',25,false,0,25,'pending','late_return','policy-test-partial',true,1000),
 (rid,uid,'Synthetic paid auto fee','late_fee',25,false,0,25,'paid','late_return','policy-test-paid',false,0),
 (rid,uid,'Synthetic manual fee','late_fee',25,false,0,25,'pending','admin','policy-test-manual',false,0);
 perform set_config('session_replication_role','origin',true);
end $$;
\ir ../migrations/20261114031000_retire_automatic_late_balances.sql
do $$ begin
 assert (select status='waived' from rental_charge_items where source_reference='policy-test-unpaid');
 assert (select status='waived' and allocated_payment_cents=1000 and allocated_waiver_cents=1500 and total_amount=25 from rental_charge_items where source_reference='policy-test-partial');
 assert (select status='paid' and total_amount=25 from rental_charge_items where source_reference='policy-test-paid');
 assert (select status='pending' from rental_charge_items where source_reference='policy-test-manual');
 assert (select count(*)=2 from rental_audit_events where event_type='automatic_late_policy_retirement');
 raise notice 'PASS: unpaid automatic remainder waived, partial and paid money retained, manual fee retained, cleanup audited';
end $$;
