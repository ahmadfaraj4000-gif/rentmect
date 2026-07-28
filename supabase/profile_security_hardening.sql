-- Rent Me CT profile write hardening.
-- Run this in the Supabase SQL editor before deploying the matching client portal change.

alter table public.profiles
  add column if not exists date_of_birth date;

create or replace function public.save_customer_profile_contact_details(
  p_full_name text,
  p_phone text,
  p_address text,
  p_date_of_birth date
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_profile public.profiles%rowtype;
  v_phone text := nullif(trim(p_phone), '');
  v_phone_changed boolean := false;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to save a profile.';
  end if;

  if p_date_of_birth is null or p_date_of_birth > current_date then
    raise exception 'A valid date of birth is required.';
  end if;

  select *
    into v_profile
    from public.profiles
    where id = v_user_id
    for update;

  if found then
    v_phone_changed := coalesce(v_profile.phone, '') is distinct from coalesce(v_phone, '');

    update public.profiles
      set email = coalesce(v_email, email),
          full_name = nullif(trim(p_full_name), ''),
          phone = v_phone,
          address = nullif(trim(p_address), ''),
          date_of_birth = p_date_of_birth,
          phone_verified = case when v_phone_changed then false else phone_verified end,
          phone_verified_at = case when v_phone_changed then null else phone_verified_at end,
          phone_verification_method = case when v_phone_changed then null else phone_verification_method end,
          phone_verification_updated_at = case when v_phone_changed then null else phone_verification_updated_at end
      where id = v_user_id
      returning * into v_profile;
  else
    insert into public.profiles (
      id,
      email,
      full_name,
      phone,
      address,
      date_of_birth,
      phone_verified,
      phone_verified_at,
      phone_verification_method,
      phone_verification_updated_at
    )
    values (
      v_user_id,
      v_email,
      nullif(trim(p_full_name), ''),
      v_phone,
      nullif(trim(p_address), ''),
      p_date_of_birth,
      false,
      null,
      null,
      null
    )
    returning * into v_profile;
  end if;

  return v_profile;
end;
$$;

drop function if exists public.save_customer_profile_contact_details(text, text, text);
revoke all on function public.save_customer_profile_contact_details(text, text, text, date) from public;
grant execute on function public.save_customer_profile_contact_details(text, text, text, date) to authenticated;

-- Remove legacy owner-write policies. The client portal now writes customer profile
-- contact details through save_customer_profile_contact_details instead.
drop policy if exists "Users can insert own profile" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Users can create their own profile" on public.profiles;
drop policy if exists "Profiles are editable by owner or admins" on public.profiles;

drop policy if exists "Admins can create profiles" on public.profiles;
create policy "Admins can create profiles"
  on public.profiles
  for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "Admins can update profiles" on public.profiles;
create policy "Admins can update profiles"
  on public.profiles
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());
