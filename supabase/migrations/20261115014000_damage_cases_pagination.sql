begin;
create index if not exists vehicle_reports_status_page_idx on public.vehicle_reports(status,created_at desc,id desc);
create index if not exists vehicle_reports_created_page_idx on public.vehicle_reports(created_at desc,id desc);
create function public.admin_damage_cases_page(p_filter text default 'open',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('customer.manage'),false) then raise exception 'Case management permission required.'; end if;
 if p_filter is null or p_filter not in ('open','resolved','all','deposit_held','blocked') then raise exception 'Invalid case filter.'; end if;
 if p_offset is null or p_offset<0 then raise exception 'Invalid page offset.'; end if;
 with page as materialized (
  select c.id,c.created_at,c.status,c.issue_type,c.report_type,p.full_name,r.id as rental_id,v.name as vehicle_name
  from vehicle_reports c left join profiles p on p.id=c.user_id
  left join rentals r on r.id=c.rental_id left join vehicles v on v.id=r.vehicle_id
  where case p_filter
   when 'open' then coalesce(c.status,'open') in ('open','pending','new')
   when 'resolved' then c.status='resolved'
   when 'deposit_held' then coalesce(c.deposit_held_amount,0)>0 or r.deposit_status='held'
   when 'blocked' then coalesce(p.blocked_customer,false) or p.customer_status='blocked'
   else true end
  order by c.created_at desc,c.id desc limit 26 offset p_offset
 ), shown as (select * from page order by created_at desc,id desc limit 25)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(s) order by created_at desc,id desc) from shown s),'[]'::jsonb),
 'has_more',(select count(*)>25 from page)) into result;
 return result;
end $$;
revoke all on function public.admin_damage_cases_page(text,integer) from public,anon;
grant execute on function public.admin_damage_cases_page(text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
