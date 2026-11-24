\set ON_ERROR_STOP on
begin;
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(); result jsonb; begin
 perform set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
 begin
  perform record_rental_driving_incident(rid,'denied',111,true);
  raise exception 'Third admin recorded incident';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
 result:=record_rental_driving_incident(rid,'one',101,true);
 assert (result->>'count')::integer=1 and (result->>'requires_review')::boolean;
 assert record_rental_driving_incident(rid,' ONE ',101,true)=result;
 result:=record_rental_driving_incident(rid,'two',100,false);
 assert (result->>'count')::integer=2;
 result:=record_rental_driving_incident(rid,'three',null,true);
 assert (result->>'count')::integer=3 and (result->>'requires_review')::boolean;
end $$;
rollback;
