\set ON_ERROR_STOP on
\ir ../migrations/20261114070000_preserve_paid_checkout_holds.sql
\ir ../migrations/20261114071000_customer_directory_pages.sql
\ir ../migrations/20261114072000_payment_activity_pages.sql
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; data jsonb; begin
 rid:=pg_temp.account_fixture(300,100);
 data:=admin_payment_activity_page();
 assert jsonb_typeof(data->'rows')='array';
 assert data->'totals' is not null;
 data:=admin_customer_directory_page();
 assert jsonb_typeof(data->'rows')='array';
end $$;
rollback;
\ir ../migrations/20261114073000_communication_thread_pages.sql
\ir ../migrations/20261114074000_operation_summaries.sql
\ir ../migrations/20261114075000_merchant_summary_pages.sql
\ir ../migrations/20261114076000_toll_candidate_pages.sql
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare paid_id uuid; unpaid_id uuid; partial_id uuid; data jsonb; begin
 paid_id:=pg_temp.account_fixture(300,813.67);
 unpaid_id:=pg_temp.account_fixture(300,0);
 partial_id:=pg_temp.account_fixture(300,100);
 perform set_config('session_replication_role','replica',true);
 update rentals set status='pending',starting_mileage=null,payment_due_at=now()-interval '1 day' where id in(paid_id,unpaid_id,partial_id);
 perform set_config('session_replication_role','origin',true);
 perform expire_stale_customer_checkout_holds();
 assert (select status='cancelled' from rentals where id=unpaid_id),'Unpaid expired checkout must still expire';
 assert (select status='pending' from rentals where id=partial_id),'Partial payment must survive expiration';
 assert (select status='pending' from rentals where id=paid_id),'Paid booking must survive expiration';
 perform expire_stale_customer_checkout_holds();
 assert (select status='pending' from rentals where id=partial_id),'Repeated recovery must preserve partial payment';
 perform admin_operation_summaries();
 perform admin_communication_threads();
 perform admin_merchant_workspace();
end $$;
rollback;
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; n integer; begin
 for n in 1..61 loop
  rid:=pg_temp.account_fixture(300,case when n%3=0 then 813.67 when n%3=1 then 100 else 0 end);
 end loop;
end $$;
do $$ declare rid uuid; receipt uuid:=gen_random_uuid(); n integer; begin
 rid:=pg_temp.account_fixture(300,813.67);
 perform set_config('session_replication_role','replica',true);
 insert into rental_payments(rental_id,user_id,status,total_amount,rental_amount,tax_amount,deposit_amount,refunded_amount,paid_at,deposit_refunded_at)
 select rid,user_id,'paid',813.67,483,30.67,300,25,now(),now() from rentals where id=rid;
 insert into rental_payment_refunds(id,rental_id,stripe_payment_intent_id,stripe_refund_id,amount,reason,status) values(gen_random_uuid(),rid,'pi_synthetic','re_synthetic',20,'Synthetic parity refund','succeeded');
 insert into rental_deposit_allocations(holder_rental_id,source_rental_id,amount_held,amount_released,status,payment_provider,refund_completed_at)
 values(rid,rid,300,30,'held','stripe',now());
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount,status,payment_amount_cents,payment_receipt_id)
 values(rid,(select user_id from rentals where id=rid),'Synthetic toll one','toll',11,11,'paid',1100,receipt),(rid,(select user_id from rentals where id=rid),'Synthetic toll two','toll',12,12,'paid',1200,receipt),
 (rid,(select user_id from rentals where id=rid),'Synthetic pending fee','other',13,13,'pending',null,null),(rid,(select user_id from rentals where id=rid),'Synthetic failed fee','other',14,14,'failed',null,null);
 perform set_config('session_replication_role','origin',true);
end $$;
create temporary table payment_parity as select jsonb_build_object(
 'input',jsonb_build_object('rentals',(select jsonb_agg(to_jsonb(r)||jsonb_build_object('profiles',to_jsonb(p),'vehicles',to_jsonb(v))) from rentals r left join profiles p on p.id=r.user_id left join vehicles v on v.id=r.vehicle_id),
 'rentalPayments',coalesce((select jsonb_agg(to_jsonb(p)) from rental_payments p),'[]'),
 'rentalRefunds',coalesce((select jsonb_agg(to_jsonb(p)) from rental_payment_refunds p),'[]'),
 'rentalCharges',coalesce((select jsonb_agg(to_jsonb(p)) from rental_charge_items p),'[]'),
 'depositAllocations',coalesce((select jsonb_agg(to_jsonb(p)) from rental_deposit_allocations p),'[]'),
 'externalPaymentActions',coalesce((select jsonb_agg(to_jsonb(p)) from rental_external_payment_actions p),'[]'),
 'extensionRequests',coalesce((select jsonb_agg(to_jsonb(p)) from rental_extension_requests p),'[]'),
 'stripeReconciliationIssues',coalesce((select jsonb_agg(to_jsonb(p)) from stripe_reconciliation_issues p),'[]'),
 'flexibleReceipts',admin_flexible_payment_activity()),
 'pages',jsonb_build_array(admin_payment_activity_page('all','all',0),admin_payment_activity_page('all','all',50),admin_payment_activity_page('all','all',100))) data;
\copy (select data from payment_parity) to '/tmp/rentme-screen-payment-parity.json'
do $$ declare first_page jsonb; second_page jsonb; begin
 first_page:=admin_payment_activity_page('all','all',0);
 second_page:=admin_payment_activity_page('all','all',50);
 assert jsonb_array_length(first_page->'rows')=50;
 assert first_page->'totals'=second_page->'totals','Totals cannot change with page';
 assert first_page->'totals'=admin_payment_activity_page('received','deposit',0)->'totals','Totals cannot change with filters';
 assert jsonb_array_length(admin_customer_directory_page('',0)->'rows')=50;
 assert jsonb_array_length(admin_customer_directory_page('',50)->'rows')=(select least(50,count(*)-50) from profiles where customer_deleted_at is null);
 perform set_config('request.jwt.claim.sub','',true);
 begin perform admin_payment_activity_page(); raise exception 'Anonymous payment access accepted'; exception when insufficient_privilege then null; end;
 begin perform admin_customer_directory_page(); raise exception 'Anonymous customer access accepted'; exception when insufficient_privilege then null; end;
 begin perform admin_operation_summaries(); raise exception 'Anonymous operation access accepted'; exception when insufficient_privilege then null; end;
 begin perform admin_communication_threads(); raise exception 'Anonymous communication access accepted'; exception when insufficient_privilege then null; end;
end $$;
rollback;
