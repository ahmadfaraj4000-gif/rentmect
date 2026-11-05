select set_config('request.jwt.claim.role','service_role',false);
insert into auth.users(id) values ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002'),('10000000-0000-4000-8000-000000000003');
insert into profiles values ('10000000-0000-4000-8000-000000000001','admin','owner'),('10000000-0000-4000-8000-000000000002','user','customer'),('10000000-0000-4000-8000-000000000003','admin','employee');
insert into rentals values ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002'),('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002');
insert into rental_charge_items(id,rental_id,user_id,name,charge_type,amount,total_amount,status,source_type)
select ('30000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','Toll '||i,'toll',i,i,'pending','tollspot' from generate_series(1,8) i;
insert into tollspot_transactions(rental_charge_item_id,status) select id,'matched' from rental_charge_items;
create function test_toll_request() returns jsonb language sql as $$select '{"charges":[{"id":"30000000-0000-4000-8000-000000000001","amountCents":100},{"id":"30000000-0000-4000-8000-000000000002","amountCents":200}],"amountCents":300,"paymentMethod":"cash","receivedDate":"2026-01-01","reference":"receipt-123"}'::jsonb$$;
create function test_toll_prepare(req jsonb default test_toll_request(), receipt uuid default '40000000-0000-4000-8000-000000000001', actor uuid default '10000000-0000-4000-8000-000000000001') returns jsonb language sql as $$select service_prepare_external_toll_receipt(receipt,'20000000-0000-4000-8000-000000000001',actor,req)$$;
create function expect_toll_failure(sql text,expected text) returns void language plpgsql as $$
begin
 begin execute sql; exception when others then
  if position(expected in sqlerrm)=0 then raise exception 'Expected %, received %',expected,sqlerrm; end if;
  return;
 end;
 raise exception 'Expected failure: %',sql;
end $$;
select expect_toll_failure($q$select test_toll_prepare(test_toll_request()||'{"amountCents":301}')$q$,'exactly match');
select expect_toll_failure($q$select test_toll_prepare(jsonb_set(test_toll_request(),'{charges,0,amountCents}','101'))$q$,'amount changed');
select expect_toll_failure($q$select test_toll_prepare(jsonb_set(test_toll_request(),'{charges,1,id}','"30000000-0000-4000-8000-000000000001"'))$q$,'distinct tolls');
select expect_toll_failure($q$select test_toll_prepare(actor=>'10000000-0000-4000-8000-000000000003')$q$,'permission required');
select set_config('request.jwt.claim.role','authenticated',false);
select expect_toll_failure($q$select test_toll_prepare()$q$,'Service role');
select set_config('request.jwt.claim.role','service_role',false);
update rental_charge_items set rental_id='20000000-0000-4000-8000-000000000002' where name='Toll 2';
select expect_toll_failure($q$select test_toll_prepare()$q$,'no longer eligible');
update rental_charge_items set rental_id='20000000-0000-4000-8000-000000000001',checkout_creation_token=gen_random_uuid() where name='Toll 2';
select expect_toll_failure($q$select test_toll_prepare()$q$,'no longer eligible');
update rental_charge_items set checkout_creation_token=null,admin_charge_attempted_at=now() where name='Toll 2';
select expect_toll_failure($q$select test_toll_prepare()$q$,'no longer eligible');
update rental_charge_items set admin_charge_attempted_at=null where name='Toll 2';
select test_toll_prepare();
select expect_toll_failure($q$update rental_charge_items set status='paid',payment_provider='deposit' where name='Toll 1'$q$,'external payment receipt');
select expect_toll_failure($q$update rental_charge_items set admin_charge_attempts=1 where name='Toll 2'$q$,'external payment receipt');
select expect_toll_failure($q$update rental_charge_items set checkout_creation_token=gen_random_uuid() where name='Toll 2'$q$,'external payment receipt');
select expect_toll_failure($q$update rental_charge_items set status='paid',payment_provider='stripe' where name='Toll 1'$q$,'external payment receipt');
select expect_toll_failure($q$delete from rental_charge_items where name='Toll 1'$q$,'deletion');
select expect_toll_failure($q$select test_toll_prepare(test_toll_request()||'{"reference":"different"}')$q$,'different payment');
-- A downstream failure on the second charge rolls back the first payment and
-- its TollSpot propagation, leaving the durable reservation retryable.
create function fail_second_toll() returns trigger language plpgsql as $$begin if new.name='Toll 2' and new.status='paid' then raise exception 'simulated downstream failure'; end if; return new; end $$;
create trigger test_second_toll before update on rental_charge_items for each row execute function fail_second_toll();
select expect_toll_failure($q$select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001')$q$,'simulated downstream failure');
do $$begin
 assert (select count(*)=0 from rental_charge_items where status='paid');
 assert (select count(*)=0 from tollspot_transactions where status='paid');
 assert (select status='pending' from external_toll_receipts where id='40000000-0000-4000-8000-000000000001');
end $$;
drop trigger test_second_toll on rental_charge_items;
select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001');
select test_toll_prepare();
select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',true);
do $$begin
 assert (select sum(payment_amount_cents)=300 from rental_charge_items where status='paid');
 assert (select count(*)=2 from tollspot_transactions where status='paid');
 assert (select count(*)=1 from external_toll_receipts where status='posted');
 assert (select count(*)=1 from rental_audit_events where event_type='external_toll_receipt_posted');
 assert (select count(*)=0 from rental_audit_events where event_type='external_toll_receipt_cancelled');
end $$;
select expect_toll_failure($q$update rental_charge_items set status='pending' where name='Toll 1'$q$,'external payment receipt');
select expect_toll_failure($q$update rental_charge_items set total_amount=100 where name='Toll 1'$q$,'external payment receipt');
select test_toll_prepare('{"charges":[{"id":"30000000-0000-4000-8000-000000000003","amountCents":300}],"amountCents":300,"paymentMethod":"cash","receivedDate":"2026-01-01","reference":"cancel test"}','40000000-0000-4000-8000-000000000002');
select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001',true);
select expect_toll_failure($q$select service_finish_external_toll_receipt('40000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001')$q$,'cancelled');
update rental_charge_items set status='waived' where name='Toll 3';
do $$begin
 assert (select external_toll_receipt_id is null from rental_charge_items where name='Toll 3');
 assert (select count(*)=1 from external_toll_receipt_allocations where receipt_id='40000000-0000-4000-8000-000000000002');
end $$;
