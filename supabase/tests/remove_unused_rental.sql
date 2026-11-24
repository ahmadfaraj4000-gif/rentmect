\set ON_ERROR_STOP on
begin;
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(0,0); rid2 uuid:=pg_temp.account_fixture(0,0); begin
 perform set_config('session_replication_role','replica',true);
 update rentals set status='documents_needed',starting_mileage=null,agreement_signed=false where id in (rid,rid2);
 update rentals set agreement_signed=true where id=rid2;
 perform set_config('session_replication_role','origin',true);
 perform set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
 begin
   perform remove_unused_rental(rid,'delete');
   raise exception 'Unexpected removal by third administrator';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
 assert remove_unused_rental(rid)='delete';
 assert remove_unused_rental(rid,'delete')='delete';
 assert not exists(select from rentals where id=rid);
 assert remove_unused_rental(rid2)='archive';
 assert remove_unused_rental(rid2,'archive')='archive';
 assert exists(select from rentals where id=rid2 and status='cancelled' and agreement_signed);
end $$;
rollback;
