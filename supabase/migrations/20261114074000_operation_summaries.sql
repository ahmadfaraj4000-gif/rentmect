begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create function public.admin_operation_summaries() returns jsonb language plpgsql stable set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.queue'),false) then raise exception 'Queue access is required.' using errcode='42501'; end if;
 with active as materialized(select id,user_id,vehicle_id,status,payment_status,agreement_signed,pickup_date,pickup_time,return_date,return_time from public.rentals where status not in ('completed','cancelled')),
 rental_rows as (select r.*,jsonb_build_object('name',v.name) vehicles,jsonb_build_object('full_name',p.full_name,'identity_verification_status',p.identity_verification_status,'phone_verified',p.phone_verified,'phone_verified_at',p.phone_verified_at) profiles
 from active r left join public.profiles p on p.id=r.user_id left join public.vehicles v on v.id=r.vehicle_id),
 docs as (select d.id,d.user_id,d.rental_id,d.document_type,d.status,d.created_at,d.extension_request_id,jsonb_build_object('full_name',p.full_name) profiles
 from public.rental_documents d left join public.profiles p on p.id=d.user_id where d.rental_id in (select id from active) or d.document_type='license' and d.user_id in (select user_id from active)),
 extensions as (select e.id,e.rental_id,e.user_id,e.status,e.requested_return_date,e.requested_return_time,e.extension_total_amount,e.request_kind,to_jsonb(r) rentals from public.rental_extension_requests e join rental_rows r on r.id=e.rental_id where e.status in ('pending','approved_pending_payment')),
 messages as (select m.id,m.user_id,m.rental_id,m.sender_role,m.read_by_admin,left(m.message,200) message from public.rental_messages m where m.rental_id in (select id from active) and m.sender_role='client' and not m.read_by_admin),
 reports as (select id,user_id,rental_id,status,left(description,200) description from public.vehicle_reports where rental_id in (select id from active) and lower(coalesce(status,'open')) in ('open','pending','new'))
 select jsonb_build_object('rentals',coalesce((select jsonb_agg(to_jsonb(r)) from rental_rows r),'[]'),
 'documents',coalesce((select jsonb_agg(to_jsonb(d)) from docs d),'[]'),
 'extensions',coalesce((select jsonb_agg(to_jsonb(e)) from extensions e),'[]'),
 'messages',coalesce((select jsonb_agg(to_jsonb(m)) from messages m),'[]'),
 'reports',coalesce((select jsonb_agg(to_jsonb(r)) from reports r),'[]')) into result;
 return result;
end $$;
revoke all on function public.admin_operation_summaries() from public,anon;
grant execute on function public.admin_operation_summaries() to authenticated;
notify pgrst,'reload schema';
commit;
