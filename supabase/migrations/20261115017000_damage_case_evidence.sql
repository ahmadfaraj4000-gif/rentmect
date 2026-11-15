begin;
create table damage_case_attachments (
 id uuid primary key, report_id uuid not null references vehicle_reports(id), file_name text not null,
 object_path text unique not null, size_bytes integer not null check(size_bytes between 1 and 460800),
 created_at timestamptz not null default now(), uploaded_at timestamptz, created_by uuid not null
);
create index damage_case_attachments_page on damage_case_attachments(report_id,created_at,id) where uploaded_at is not null;
alter table damage_case_attachments enable row level security;
revoke all on damage_case_attachments from anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('damage-case-evidence','damage-case-evidence',false,460800,array['image/webp']);
create function admin_case_evidence_save(p_report_id uuid,p_id uuid,p_action text,p_name text default '',p_size integer default 0) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a damage_case_attachments%rowtype;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('customer.manage'),false) then raise exception 'Case management permission required.'; end if;
 perform 1 from vehicle_reports where id=p_report_id for update;
 if not found then raise exception 'Case not found.'; end if;
 select * into a from damage_case_attachments where id=p_id;
 if found and a.report_id<>p_report_id then raise exception 'Photo belongs to another case.'; end if;
 if p_action='prepare' then
  if a.id is null then
   if length(trim(p_name))=0 then raise exception 'Photo name required.'; end if;
   insert into damage_case_attachments(id,report_id,file_name,object_path,size_bytes,created_by)
   values(p_id,p_report_id,left(p_name,200),p_report_id::text||'/'||p_id::text||'.webp',p_size,auth.uid()) returning * into a;
  end if;
 elsif p_action='complete' then
  if a.id is null then raise exception 'Prepare the upload first.'; end if;
  if a.uploaded_at is null then
   if not exists(select 1 from storage.objects where bucket_id='damage-case-evidence' and name=a.object_path and (metadata->>'size')::integer=a.size_bytes and metadata->>'mimetype'='image/webp') then raise exception 'Photo upload is incomplete. Retry uploading.'; end if;
   update damage_case_attachments set uploaded_at=now() where id=a.id returning * into a;
  end if;
 else raise exception 'Unknown photo action.'; end if;
 return to_jsonb(a);
end $$;
create function admin_case_evidence_page(p_report_id uuid,p_offset integer default 0) returns jsonb
language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('customer.manage'),false) then raise exception 'Case management permission required.'; end if;
 if p_offset<0 then raise exception 'Invalid page.'; end if;
 with items as (
  select 'legacy-'||l.ordinality::text as id,'rental-documents' as bucket,l.path as object_path,regexp_replace(l.path,'^.*/','') as file_name,0 as source,l.ordinality as seq,null::timestamptz as created_at
  from vehicle_reports r cross join lateral jsonb_array_elements_text(r.photo_paths) with ordinality l(path,ordinality) where r.id=p_report_id
  union all
  select a.id::text,'damage-case-evidence',a.object_path,a.file_name,1,0,a.created_at from damage_case_attachments a where a.report_id=p_report_id and a.uploaded_at is not null
 ), page as (select * from items order by source,seq,created_at,id limit 9 offset p_offset), numbered as (select *,row_number() over(order by source,seq,created_at,id) n from page)
 select jsonb_build_object('rows',coalesce(jsonb_agg(jsonb_build_object('id',id,'bucket',bucket,'object_path',object_path,'file_name',file_name) order by n) filter(where n<=8),'[]'::jsonb),'has_more',count(*)>8) into result from numbered;
 return result;
end $$;
create policy case_evidence_read on storage.objects for select to authenticated using(bucket_id='damage-case-evidence' and public.is_admin() and public.rentmect_has_permission('customer.manage') and exists(select 1 from public.damage_case_attachments a where a.object_path=name and a.uploaded_at is not null));
create policy case_evidence_upload on storage.objects for insert to authenticated with check(bucket_id='damage-case-evidence' and public.is_admin() and public.rentmect_has_permission('customer.manage') and exists(select 1 from public.damage_case_attachments a where a.object_path=name and a.uploaded_at is null and a.created_by=auth.uid()));
-- Storage policies need metadata reads, but direct writes remain RPC-only.
grant select on damage_case_attachments to authenticated;
create policy case_evidence_metadata_read on damage_case_attachments for select to authenticated using(public.is_admin() and public.rentmect_has_permission('customer.manage'));
revoke all on function admin_case_evidence_page(uuid,integer),admin_case_evidence_save(uuid,uuid,text,text,integer) from public,anon;
grant execute on function admin_case_evidence_page(uuid,integer),admin_case_evidence_save(uuid,uuid,text,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
