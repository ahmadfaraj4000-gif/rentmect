begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create function public.admin_customer_directory_page(p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql stable set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.customers'),false) then
  raise exception 'Customer access is required.' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or length(p_search)>140 then raise exception 'Invalid customer page.'; end if;
 with page as materialized (
  select p.id,p.full_name,p.email,p.phone,p.phone_verified,p.role,p.customer_status,p.blocked_customer,p.created_at
  from public.profiles p where p.customer_deleted_at is null
  and (coalesce(p_search,'')='' or concat_ws(' ',p.full_name,p.email,p.phone,p.address,p.customer_status,p.id) ilike '%'||p_search||'%'
   or (length(regexp_replace(p_search,'[^0-9]','','g'))>=3 and regexp_replace(coalesce(p.phone,''),'[^0-9]','','g') like '%'||regexp_replace(p_search,'[^0-9]','','g')||'%')
   or exists(select 1 from public.rentals r join public.vehicles v on v.id=r.vehicle_id where r.user_id=p.id and concat_ws(' ',r.status,v.name) ilike '%'||p_search||'%'))
  order by p.created_at desc,p.id desc offset p_offset limit 51
 ), visible as (select * from page order by created_at desc,id desc limit 50), summaries as (
  select p.*,coalesce(a.rental_count,0) as rental_count,latest.latest_rental,
   jsonb_build_object('level',case when risk.score>=6 then 'high' when risk.score>=3 then 'medium' else 'low' end,
    'summary',case when coalesce(p.blocked_customer,false) or p.customer_status='blocked' or coalesce(a.blocked,false) then 'Blocked customer flag is active.'
     when risk.score=0 then 'Clean history based on available records.' else 'Review history before approving another rental.' end) as risk
  from visible p
  left join lateral (select count(*) as rental_count,bool_or(coalesce(r.blocked_customer,false)) as blocked,
   count(*) filter(where r.status='overdue' or coalesce((to_jsonb(r)->>'late_return_count')::integer,0)>0 or
    (r.status in ('active','rented','overdue','return_initiated') and public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York'<now())) as late,
   coalesce(sum(coalesce((to_jsonb(r)->>'chargeback_count')::integer,0)),0) as chargebacks,
   coalesce(sum(r.deposit_held_amount),0) as deposits from public.rentals r where r.user_id=p.id) a on true
  left join lateral (select jsonb_build_object('status',r.status,'pickup_date',r.pickup_date,'pickup_time',r.pickup_time,'vehicle_name',v.name) as latest_rental
   from public.rentals r left join public.vehicles v on v.id=r.vehicle_id where r.user_id=p.id order by r.created_at desc,r.id desc limit 1) latest on true
  cross join lateral (select (case when coalesce(p.blocked_customer,false) or p.customer_status='blocked' or coalesce(a.blocked,false) then 6 else 0 end)
   +a.late*2+a.chargebacks*3+(case when a.deposits>0 then 1 else 0 end)
   +(select count(*) from public.rental_documents d where d.user_id=p.id and d.status='rejected')
   +(select count(*)*2 from public.vehicle_reports r where r.user_id=p.id and lower(coalesce(r.status,'open')) in ('open','pending','new')) as score) risk
 ) select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(s) order by created_at desc,id desc) from summaries s),'[]'::jsonb),
 'has_more',(select count(*)>50 from page)) into result;
 return result;
end $$;
revoke all on function public.admin_customer_directory_page(text,integer) from public,anon;
grant execute on function public.admin_customer_directory_page(text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
