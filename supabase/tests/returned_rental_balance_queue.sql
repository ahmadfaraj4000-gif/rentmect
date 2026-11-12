\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; cid uuid; result jsonb; rows jsonb; req jsonb; receipt uuid:=gen_random_uuid(); begin
 rid:=pg_temp.account_fixture(300,813.67);
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now() where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
 select rid,user_id,'Return charges','cleaning',445,false,445,'manual' from rentals where id=rid returning id into cid;
 req:=jsonb_build_object('chargeIds',jsonb_build_array(cid),'expectedHeld',300,'expectedCharges',445,'reason','Reviewed documented return charges.');
 result:=service_apply_deposit_review(gen_random_uuid(),rid,auth.uid(),req,
 (select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
 assert result->>'applied'='300' or (result->>'applied')::numeric=300;
 perform set_config('request.jwt.claim.role','authenticated',true);
 perform set_config('role','authenticated',true);
 rows:=admin_rental_list('needs_action','',0,25,null);
 assert exists(select 1 from jsonb_array_elements(rows->'rows') x where x->>'id'=rid::text and (x->>'returned_balance_due')::numeric=145),rows::text;
 assert (rows->'counts'->>'needs_action')::integer=1;
 rows:=admin_rental_list('deposit_review','',0,5,null);
 assert not exists(select 1 from jsonb_array_elements(rows->'rows') x where x->>'id'=rid::text);
 rows:=admin_rental_list('archive','',0,5,null);
 assert not exists(select 1 from jsonb_array_elements(rows->'rows') x where x->>'id'=rid::text);
 perform set_config('role','none',true);
 -- Collect the remaining balance through the normal payment ledger.
 perform set_config('request.jwt.claim.role','service_role',true);
 req:=jsonb_build_object('version',2,'kind','rental_payment','funding','external','amountCents',14500,'rentalAmountCents',0,
 'depositAmountCents',0,'expectedDepositDueCents',0,'expectedRentalDueCents',0,'creditAmountCents',0,'paymentMethod','cash','receivedDate',current_date,
 'charges',jsonb_build_array(jsonb_build_object('id',cid,'amountCents',14500,'expectedRemainingCents',14500)));
 perform service_prepare_external_payment(receipt,rid,auth.uid(),req);
 perform service_finish_external_payment(receipt,auth.uid(),false);
 perform set_config('request.jwt.claim.role','authenticated',true);
 rows:=admin_rental_list('needs_action','',0,25,null);
 assert not exists(select 1 from jsonb_array_elements(rows->'rows') x where x->>'id'=rid::text);
 rows:=admin_rental_list('archive','',0,5,null);
 assert exists(select 1 from jsonb_array_elements(rows->'rows') x where x->>'id'=rid::text);
 raise notice 'PASS: $445 - $300 deposit = $145 in Needs Action; settlement moves rental to Archive';
end $$;
rollback;
