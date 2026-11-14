begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create function public.admin_communication_threads(p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql stable set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.communications'),false) then raise exception 'Communication access is required.' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or length(p_search)>120 then raise exception 'Invalid conversation page.'; end if;
 with customers as materialized (
 select m.user_id,max(m.created_at) latest_at,count(*) filter(where m.sender_role<>'admin' and not m.read_by_admin) unread
 from public.rental_messages m group by m.user_id
 ), page as materialized (
 select c.user_id,c.latest_at,c.unread,p.full_name,p.email,p.phone,r.id rental_id,v.name vehicle_name,r.pickup_date,r.pickup_time,
 left(latest.message,120) preview from customers c join public.profiles p on p.id=c.user_id
 join lateral (select id,vehicle_id,pickup_date,pickup_time from public.rentals where user_id=c.user_id order by created_at desc,id desc limit 1) r on true
 left join public.vehicles v on v.id=r.vehicle_id
 left join lateral (select message from public.rental_messages where user_id=c.user_id order by created_at desc,id desc limit 1) latest on true
 where coalesce(p_search,'')='' or concat_ws(' ',p.full_name,p.email,p.phone,latest.message) ilike '%'||p_search||'%'
 order by c.latest_at desc,c.user_id desc offset p_offset limit 51
 ), visible as (select * from page order by latest_at desc,user_id desc limit 50)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(v) order by latest_at desc,user_id desc) from visible v),'[]'::jsonb),
 'has_more',(select count(*)>50 from page),'unread',(select coalesce(sum(unread),0) from customers)) into result;
 return result;
end $$;
revoke all on function public.admin_communication_threads(text,integer) from public,anon;
grant execute on function public.admin_communication_threads(text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
