begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create function public.admin_toll_rental_candidates(p_transaction_id uuid,p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql stable set search_path=pg_catalog,public as $$
declare result jsonb; t public.tollspot_transactions%rowtype;
begin
 if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.tolls'),false) then raise exception 'Toll access is required.' using errcode='42501'; end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or length(p_search)>140 then raise exception 'Invalid candidate page.'; end if;
 select * into strict t from public.tollspot_transactions where id=p_transaction_id;
 with candidates as (
 select r.id,r.user_id,r.vehicle_id,r.status,r.created_at,r.pickup_date,r.pickup_time,r.return_date,r.return_time,r.inspection_completed_at,
 jsonb_build_object('full_name',p.full_name,'email',p.email,'phone',p.phone) profiles,jsonb_build_object('name',v.name,'plate_number',v.plate_number) vehicles,
 exists(select 1 from public.rental_vehicle_assignments a where a.rental_id=r.id and a.vehicle_id=t.vehicle_id and t.occurred_at>=a.assigned_from and (a.assigned_until is null or t.occurred_at<=a.assigned_until)) exact_possession,
 (r.vehicle_id=t.vehicle_id or exists(select 1 from public.rental_vehicle_assignments a where a.rental_id=r.id and a.vehicle_id=t.vehicle_id)) same_vehicle,
 public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York' starts,
 coalesce(r.inspection_completed_at,public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') ends
 from public.rentals r left join public.profiles p on p.id=r.user_id left join public.vehicles v on v.id=r.vehicle_id
 where r.status<>'cancelled' and r.user_id is not null and (coalesce(p_search,'')='' or concat_ws(' ',r.id,p.full_name,p.email,p.phone,v.name,v.plate_number) ilike '%'||p_search||'%')
 ), ranked as (select c.*,case when exact_possession then 0 when same_vehicle and t.occurred_at between starts and ends then 1 when t.occurred_at between starts and ends then 2 when same_vehicle then 3 else 4 end rank,
 greatest(extract(epoch from starts-t.occurred_at),extract(epoch from t.occurred_at-ends),0) distance from candidates c),
 page as materialized(select * from ranked order by rank,distance,created_at desc,id desc offset p_offset limit 51),
 visible as (select * from page order by rank,distance,created_at desc,id desc limit 50)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(v)-'rank'-'distance'-'starts'-'ends'-'exact_possession'-'same_vehicle' order by rank,distance,created_at desc,id desc) from visible v),'[]'),
 'assignments',coalesce((select jsonb_agg(jsonb_build_object('rental_id',a.rental_id,'vehicle_id',a.vehicle_id,'assigned_from',a.assigned_from,'assigned_until',a.assigned_until,'source',a.source)) from public.rental_vehicle_assignments a where a.rental_id in(select id from visible)),'[]'),
 'has_more',(select count(*)>50 from page)) into result;
 return result;
end $$;
revoke all on function public.admin_toll_rental_candidates(uuid,text,integer) from public,anon;
grant execute on function public.admin_toll_rental_candidates(uuid,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
