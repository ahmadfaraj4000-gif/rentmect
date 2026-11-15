\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(300,813.67); cid uuid; cid2 uuid; customer uuid; result jsonb; begin
 select user_id into customer from rentals where id=rid;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',ending_mileage=1234,inspection_completed_at=now() where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
 insert into vehicle_reports(rental_id,user_id,description) values(rid,customer,'Synthetic damage case') returning id into cid;
 insert into vehicle_reports(rental_id,user_id,description) values(rid,customer,'Another synthetic case') returning id into cid2;
 perform admin_damage_case_action(cid,'hold','Pending repair review');
 assert (select damage_deposit_hold and deposit_held_amount=300 and deposit_release_due_at is null from rentals where id=rid);
 assert (select not rentmect_needs_deposit_review(r) from rentals r where id=rid),'Held case still in deposit-review queue';
 assert exists(select 1 from jsonb_array_elements(admin_rental_list('archive','',0,25,null)->'rows') item where item->>'id'=rid::text and (item->>'damage_deposit_hold')::boolean),'Held rental absent from Archive';
 assert (select deposit_hold_active and deposit_held_amount=300 from vehicle_reports where id=cid);
 perform admin_damage_case_action(cid2,'hold','Second case pending');
 perform admin_damage_case_action(cid,'resolve','First case cleared');
 assert (select damage_deposit_hold from rentals where id=rid),'Another case hold was cleared';
 assert exists(select 1 from jsonb_array_elements(rentmect_deposit_chain_release_blockers(rid)) b where b->>'type'='open_vehicle_report');
 perform admin_damage_case_action(cid2,'resolve','Inspection cleared');
 assert (select not damage_deposit_hold and rentmect_needs_deposit_review(r) and deposit_held_amount=300 from rentals r where id=rid);
 assert not exists(select 1 from jsonb_array_elements(rentmect_deposit_chain_release_blockers(rid)) b where b->>'type'='open_vehicle_report');
 perform admin_set_customer_status(customer,'blocked','Synthetic case block');
 assert (select blocked_customer and customer_status='blocked' from profiles where id=customer);
 perform admin_set_customer_status(customer,'good','Synthetic case unblock');
 assert (select not blocked_customer and customer_status='good' from profiles where id=customer);
 assert (select sum(amount_released)=0 from rental_deposit_allocations where holder_rental_id=rid),'Case action moved money';
 raise notice 'PASS case holds, archive classification, multi-case resolution, customer block and unchanged money';
end $$;
rollback;
