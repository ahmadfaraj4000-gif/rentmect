\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid:=pg_temp.account_fixture(300,813.67); report uuid; attachment uuid; prepared jsonb; firstpage jsonb; secondpage jsonb; begin
 insert into vehicle_reports(rental_id,user_id,description,photo_paths) select id,user_id,'Synthetic evidence case','["old/a.jpg","old/b.pdf"]' from rentals where id=rid returning id into report;
 for i in 1..18 loop
  attachment:=gen_random_uuid();
  prepared:=admin_case_evidence_save(report,attachment,'prepare','photo.webp',100);
  assert (admin_case_evidence_page(report,0)->'rows') is not null;
  insert into storage.objects(bucket_id,name,metadata) values('damage-case-evidence',prepared->>'object_path','{"size":100,"mimetype":"image/webp"}');
  perform admin_case_evidence_save(report,attachment,'complete');
  perform admin_case_evidence_save(report,attachment,'complete');
 end loop;
 firstpage:=admin_case_evidence_page(report,0); secondpage:=admin_case_evidence_page(report,8);
 assert jsonb_array_length(firstpage->'rows')=8 and (firstpage->>'has_more')::boolean;
 assert jsonb_array_length(secondpage->'rows')=8 and (secondpage->>'has_more')::boolean;
 assert jsonb_array_length(admin_case_evidence_page(report,16)->'rows')=4;
 assert not (admin_case_evidence_page(report,16)->>'has_more')::boolean;
 assert not exists(select 1 from jsonb_array_elements(firstpage->'rows') a join jsonb_array_elements(secondpage->'rows') b on a->>'id'=b->>'id');
 assert not exists(select 1 from jsonb_array_elements(firstpage->'rows') a where a ? 'signedUrl');
 attachment:=gen_random_uuid();perform admin_case_evidence_save(report,attachment,'prepare','incomplete.webp',100);
 begin perform admin_case_evidence_save(report,attachment,'complete');raise exception 'Incomplete upload accepted';exception when raise_exception then if sqlerrm='Incomplete upload accepted' then raise;end if;end;
 assert (select count(*)=18 from damage_case_attachments where report_id=report and uploaded_at is not null);
 perform set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
 begin perform admin_case_evidence_page(report,0);raise exception 'Unauthorized read accepted';exception when raise_exception then if sqlerrm='Unauthorized read accepted' then raise;end if;end;
end $$;
rollback;
