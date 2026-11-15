\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(300,813.67); first_page jsonb; next_page jsonb; begin
 insert into vehicle_reports(rental_id,user_id,description,status,created_at,admin_notes,photo_paths)
 select rid,r.user_id,'Private full description',case when n=31 then 'resolved' when n=30 then 'pending' when n=29 then 'new' else 'open' end,now()-n*interval '1 minute','Private notes','["private/photo.jpg"]'::jsonb
 from rentals r cross join generate_series(1,31) n where r.id=rid;
 first_page:=admin_damage_cases_page('open',0);next_page:=admin_damage_cases_page('open',25);
 assert jsonb_array_length(first_page->'rows')=25 and (first_page->>'has_more')::boolean;
 assert jsonb_array_length(next_page->'rows')=5 and not (next_page->>'has_more')::boolean;
 assert not exists(select 1 from jsonb_array_elements(first_page->'rows') a join jsonb_array_elements(next_page->'rows') b on a->>'id'=b->>'id');
 assert not exists(select 1 from jsonb_array_elements(first_page->'rows') a where a ?| array['description','admin_notes','photo_paths']);
 assert jsonb_array_length(admin_damage_cases_page('resolved',0)->'rows')=1;
 assert jsonb_array_length(admin_damage_cases_page('all',25)->'rows')=6;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform admin_damage_cases_page('all',0);raise exception 'Unauthorized report read accepted';
 exception when others then if sqlerrm not like '%permission required%' then raise;end if;end;
 raise notice 'PASS bounded case pages, filters, private detail exclusion and access control';
end $$;
rollback;
