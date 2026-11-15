\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(300,813.67); cid uuid; begin
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',ending_mileage=1234,inspection_completed_at=now() where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status) values(rid,rid,'local',300,'held');
 perform admin_retain_rental_deposit(rid,'Deposit kept after return');
 assert (select damage_deposit_hold and manual_deposit_hold and deposit_held_reviewed_at is not null and not rentmect_needs_deposit_review(r) from rentals r where id=rid);
 assert exists(select 1 from jsonb_array_elements(admin_rental_list('archive','',0,25,null)->'rows') j where j->>'id'=rid::text);
 insert into vehicle_reports(rental_id,user_id,description) select id,user_id,'Synthetic case' from rentals where id=rid returning id into cid;
 perform admin_damage_case_action(cid,'resolve','Case cleared');
 assert (select damage_deposit_hold from rentals where id=rid),'Resolving a case erased an independent rental hold';
 assert exists(select 1 from jsonb_array_elements(rentmect_deposit_chain_release_blockers(rid)) b where b->>'type'='deposit_retained');
 perform admin_resume_deposit_review(rid);
 assert (select not damage_deposit_hold and not manual_deposit_hold and rentmect_needs_deposit_review(r) from rentals r where id=rid);
 assert not exists(select 1 from jsonb_array_elements(rentmect_deposit_chain_release_blockers(rid)) b where b->>'type'='deposit_retained');
 assert (select sum(amount_released)=0 from rental_deposit_allocations where holder_rental_id=rid);
end $$;
rollback;
