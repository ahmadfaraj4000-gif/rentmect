\set ON_ERROR_STOP on
begin;
create schema vault;
create table vault.decrypted_secrets(name text, decrypted_secret text);
insert into vault.decrypted_secrets values('rental_return_recovery_code','synthetic-code');
\ir fixtures/account_fixture.sql
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
do $$ declare rid uuid:=pg_temp.account_fixture(); rr rentals; result jsonb; prev rentals; begin
 update rentals set status='return_initiated' where id=rid returning * into prev;
 rr:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,false,'release',null,'available',false,null);
 assert rr.status='completed';
 result:=undo_rental_return(rid,'wrong',rr.inspection_completed_at);
 assert result ? 'error';
 result:=undo_rental_return(rid,'synthetic-code',rr.inspection_completed_at);
 assert result->>'status'='reversed';
 assert (select status=prev.status and return_date=prev.return_date and return_time=prev.return_time and inspection_completed_at is null from rentals where id=rid);
 assert exists(select from rentmect_vehicle_conflicts(rr.vehicle_id,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 assert undo_rental_return(rid,'synthetic-code',rr.inspection_completed_at)->>'status'='already_reversed';
 raise notice 'PASS: wrong code, successful reversal, possession lock, due time and duplicate submission.';
end $$;
rollback;
