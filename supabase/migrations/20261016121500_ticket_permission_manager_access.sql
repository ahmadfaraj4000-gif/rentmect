begin;

-- Production represents its permission administrator as an employee with
-- per-account overrides. Preserve the existing authority boundary rather than
-- enabling the new permissions for every employee or changing anyone's role.
do $$
declare staff record; original_subject text:=current_setting('request.jwt.claim.sub',true); context jsonb;
begin
 for staff in select id from public.profiles where role='admin' loop
  perform set_config('request.jwt.claim.sub',staff.id::text,true);
  context:=public.get_admin_staff_context();
  if coalesce((context->>'can_manage_employee_permissions')::boolean,false) then
   insert into public.staff_permission_overrides(user_id,permission_key,enabled,reason)
   select staff.id,key,true,'Ticket Resolution rollout: existing employee-permission administrator'
   from unnest(array['tab.tickets','ticket.manage']) key
   on conflict(user_id,permission_key) do nothing;
  end if;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(original_subject,''),true);
end$$;

notify pgrst,'reload schema';
commit;
