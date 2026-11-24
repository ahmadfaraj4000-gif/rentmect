\set ON_ERROR_STOP on
begin;
create schema vault;
create table vault.decrypted_secrets(name text, decrypted_secret text);
insert into vault.decrypted_secrets values('rental_return_recovery_code','synthetic-code');
\ir fixtures/account_fixture.sql
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
do $$ declare rid uuid; rr rentals; result jsonb; prev rentals; prior_status text; tab text; begin
 foreach tab in array array['needs_action','returns_today','extensions','maintenance','all','cars_out','deposit_review','archive','ready_pickup',null] loop
 foreach prior_status in array array['active','return_initiated'] loop
 rid:=pg_temp.account_fixture();
 select * into strict prev from rentals where id=rid;
 if prior_status='return_initiated' then
   update rentals set status=prior_status where id=rid returning * into prev;
 end if;
 rr:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,false,'release',null,'available',false,jsonb_build_object('origin_tab',tab));
 assert rr.status='completed';
 if prior_status='active' then
   begin
     update rentals set status='active',inspection_completed_at=null where id=rid;
     raise exception 'Unverified direct restoration accepted';
   exception when raise_exception then
     if sqlerrm not like 'Complete the security deposit step%' and sqlerrm not like 'Stripe Identity verification is required%' then raise; end if;
   end;
 end if;
 result:=undo_rental_return(rid,'wrong',rr.inspection_completed_at);
 assert result ? 'error';
 result:=undo_rental_return(rid,'synthetic-code',rr.inspection_completed_at);
 assert result->>'status'='reversed';
 assert (result->>'origin_tab') is not distinct from tab;
 assert (select status=prev.status and return_date=prev.return_date and return_time=prev.return_time and inspection_completed_at is null from rentals where id=rid);
 assert exists(select from rentmect_vehicle_conflicts(rr.vehicle_id,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 result:=undo_rental_return(rid,'synthetic-code',rr.inspection_completed_at);
 assert result->>'status'='already_reversed' and (result->>'origin_tab') is not distinct from tab;
 end loop;
 end loop;
 raise notice 'PASS: wrong code, successful reversal, possession lock, due time and duplicate submission.';
end $$;
rollback;
