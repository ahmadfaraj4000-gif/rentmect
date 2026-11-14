begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
create function public.admin_audit_history_page(p_search text default '',p_actor text default '',
 p_entity text default '',p_action text default '',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
 if auth.uid() is null or not coalesce(public.rentmect_has_permission('audit.view'),false) then
  raise exception 'Audit access is required.'; end if;
 if p_offset<0 or p_offset>1000000 or greatest(length(p_search),length(p_actor),length(p_entity),length(p_action))>160 then
  raise exception 'Invalid audit search.'; end if;
 with page as materialized (
  select id,actor_user_id,actor_email,actor_role,action,entity_type,entity_id,changed_fields,created_at
  from public.admin_audit_logs l
  where (coalesce(p_actor,'')='' or coalesce(actor_email,'System process') ilike '%'||p_actor||'%'
    or actor_user_id::text=p_actor)
   and (coalesce(p_entity,'')='' or entity_type=p_entity)
   and (coalesce(p_action,'')='' or action=p_action)
   and (coalesce(p_search,'')='' or concat_ws(' ',actor_email,actor_user_id::text,action,entity_type,entity_id,
    array_to_string(changed_fields,' ')) ilike '%'||p_search||'%')
  order by created_at desc,id desc offset p_offset limit 51
 ), visible as (select * from page order by created_at desc,id desc limit 50)
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(v) order by created_at desc,id desc) from visible v),'[]'::jsonb),
  'has_more',(select count(*)>50 from page)) into result;
 return result;
end $$;
create function public.admin_audit_history_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
begin
 if auth.uid() is null or not coalesce(public.rentmect_has_permission('audit.view'),false) then
  raise exception 'Audit access is required.'; end if;
 return (select jsonb_build_object('before',old_values,'after',new_values,'metadata',metadata)
  from public.admin_audit_logs where id=p_id);
end $$;
revoke all on function public.admin_audit_history_page(text,text,text,text,integer) from public,anon;
revoke all on function public.admin_audit_history_detail(uuid) from public,anon;
grant execute on function public.admin_audit_history_page(text,text,text,text,integer) to authenticated;
grant execute on function public.admin_audit_history_detail(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
