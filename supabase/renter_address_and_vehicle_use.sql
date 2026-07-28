-- Adds a required renter-stated vehicle purpose and saves it through the
-- existing security-definer profile contact RPC.

alter table public.profiles
  add column if not exists intended_vehicle_use text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_intended_vehicle_use_length_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_intended_vehicle_use_length_check
      check (
        intended_vehicle_use is null
        or char_length(trim(intended_vehicle_use)) between 3 and 500
      );
  end if;
end;
$$;

create or replace function public.save_customer_profile_contact_details(
  p_full_name text,
  p_phone text,
  p_address text,
  p_date_of_birth date,
  p_intended_vehicle_use text
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
  v_address text := nullif(trim(p_address), '');
  v_intended_use text := nullif(trim(p_intended_vehicle_use), '');
  v_phone_changed boolean := false;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to save a profile.';
  end if;
  if p_date_of_birth is null or p_date_of_birth > current_date then
    raise exception 'A valid date of birth is required.';
  end if;
  if v_address is null or char_length(v_address) > 240 then
    raise exception 'A valid home address is required.';
  end if;
  if v_intended_use is null or char_length(v_intended_use) not between 3 and 500 then
    raise exception 'Describe what you intend to use the vehicle for.';
  end if;

  select * into v_profile
    from public.profiles
    where id = v_user_id
    for update;

  if found then
    v_phone_changed := coalesce(v_profile.phone, '') is distinct from coalesce(v_phone, '');
    update public.profiles
      set email = coalesce(v_email, email),
          full_name = nullif(trim(p_full_name), ''),
          phone = v_phone,
          address = v_address,
          date_of_birth = p_date_of_birth,
          intended_vehicle_use = v_intended_use,
          phone_verified = case when v_phone_changed then false else phone_verified end,
          phone_verified_at = case when v_phone_changed then null else phone_verified_at end,
          phone_verification_method = case when v_phone_changed then null else phone_verification_method end,
          phone_verification_updated_at = case when v_phone_changed then null else phone_verification_updated_at end
      where id = v_user_id
      returning * into v_profile;
  else
    insert into public.profiles (
      id, email, full_name, phone, address, date_of_birth,
      intended_vehicle_use, phone_verified
    ) values (
      v_user_id, v_email, nullif(trim(p_full_name), ''), v_phone, v_address,
      p_date_of_birth, v_intended_use, false
    ) returning * into v_profile;
  end if;

  return v_profile;
end;
$$;

drop function if exists public.save_customer_profile_contact_details(text, text, text, date);
revoke all on function public.save_customer_profile_contact_details(text, text, text, date, text) from public;
grant execute on function public.save_customer_profile_contact_details(text, text, text, date, text) to authenticated;

-- Do not copy the renter's stated purpose into operational audit snapshots.
create or replace function public.rentmect_audit_snapshot(
  p_table_name text,
  p_row jsonb
) returns jsonb
language plpgsql
immutable
as $$
begin
  if p_row is null then return null; end if;
  return p_row - array[
    'agreement_snapshot', 'agreement_hash', 'agreement_ip',
    'agreement_user_agent', 'drivers_license_number',
    'insurance_policy_number', 'email', 'phone', 'address', 'date_of_birth',
    'intended_vehicle_use', 'storage_path', 'file_path', 'photo_paths',
    'stripe_customer_id', 'stripe_identity_verification_session_id',
    'identity_verification_error_code', 'signature_data', 'user_agent'
  ]::text[]
  - case when p_table_name = 'rental_messages' then 'message' else '__keep__' end;
end;
$$;
