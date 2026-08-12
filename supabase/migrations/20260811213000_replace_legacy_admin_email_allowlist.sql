begin;

create or replace function public.enforce_admin_email_allowlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_auth_email text;
  v_actor_role text;
  v_actor_email text;
begin
  if lower(coalesce(new.role, 'client')) <> 'admin' then return new; end if;
  select lower(trim(auth_user.email)) into v_auth_email from auth.users auth_user where auth_user.id = new.id;
  if v_auth_email is null or v_auth_email <> lower(trim(coalesce(new.email, v_auth_email))) then raise exception 'The staff profile must match its Auth login email.'; end if;
  if new.staff_role not in ('owner', 'operations_manager', 'employee') then raise exception 'Choose a valid staff role before granting admin portal access.'; end if;
  if auth.uid() is null then return new; end if;
  select profile.staff_role, lower(coalesce(profile.email, '')) into v_actor_role, v_actor_email from public.profiles profile where profile.id = auth.uid();
  if v_actor_role <> 'owner' and v_actor_email <> 'anconamgt@aol.com' then raise exception 'Only an owner or authorized Operations Manager can grant staff access.'; end if;
  if new.staff_role = 'owner' and v_actor_role <> 'owner' then raise exception 'Only an owner can grant owner access.'; end if;
  return new;
end;
$$;

drop trigger if exists profiles_enforce_admin_email_allowlist on public.profiles;
create trigger profiles_enforce_admin_email_allowlist before insert or update of role, email, staff_role on public.profiles for each row execute function public.enforce_admin_email_allowlist();
commit;
