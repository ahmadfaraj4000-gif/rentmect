-- Disposable database with the operations migration applied and two synthetic staff identities.
\set ON_ERROR_STOP on
begin;
grant usage on schema storage to authenticated;
grant select,insert on storage.objects to authenticated;
grant select on public.profiles, public.rentals to authenticated;
\ir fixtures/account_fixture.sql
select pg_temp.account_fixture() as rental_id \gset
select user_id as owner_id from rental_operations_staff where staff_name='Ancona' \gset
select user_id as employee_id from rental_operations_staff where staff_name='Jennifer' \gset
select set_config('test.rental_id', :'rental_id', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', :'owner_id', true);
insert into storage.objects(bucket_id,name) values ('rental-inspections',current_setting('test.rental_id')||'/pickup/Ancona-'||gen_random_uuid()||'.jpg');
select set_config('request.jwt.claim.sub', :'employee_id', true);
insert into storage.objects(bucket_id,name) values ('rental-inspections',current_setting('test.rental_id')||'/return/Jennifer-'||gen_random_uuid()||'.jpg');
do $$ begin
  assert (select count(*) from storage.objects where bucket_id='rental-inspections')=2;
  begin
    insert into storage.objects(bucket_id,name) values('rental-inspections',current_setting('test.rental_id')||'/return/Ancona-'||gen_random_uuid()||'.jpg');
    raise exception 'Incorrect uploader accepted';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);
do $$ begin
  assert (select count(*) from storage.objects where bucket_id='rental-inspections')=0;
  begin
    insert into storage.objects(bucket_id,name) values('rental-inspections',current_setting('test.rental_id')||'/return/Jennifer-'||gen_random_uuid()||'.jpg');
    raise exception 'Third admin upload accepted';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
