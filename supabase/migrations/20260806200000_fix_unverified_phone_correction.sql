-- Allow an unverified renter to correct a phone number even when a rental is
-- active, while retaining the verified-number lock for active rentals.
-- Formatting-only edits must not clear verification or transactional consent.

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
  v_full_name text := nullif(regexp_replace(trim(p_full_name), '\s+', ' ', 'g'), '');
  v_phone text := nullif(trim(p_phone), '');
  v_phone_normalized text := public.rentmect_normalize_phone(v_phone);
  v_saved_phone_normalized text := null;
  v_intended_use text := nullif(trim(p_intended_vehicle_use), '');
  v_phone_changed boolean := false;
  v_phone_locked boolean := false;
  v_identity_details_differ boolean := false;
  v_identity_attempted boolean := false;
  v_identity_changed boolean := false;
  v_existing_identity_error text := null;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to save a profile.';
  end if;
  if v_full_name is null or array_length(regexp_split_to_array(v_full_name, '\s+'), 1) < 2 then
    raise exception 'Enter your legal first and last name exactly as shown on your government ID.';
  end if;
  if p_date_of_birth is null or p_date_of_birth > current_date then
    raise exception 'Enter a real date of birth.';
  end if;
  if p_date_of_birth > current_date - interval '21 years' then
    raise exception 'Renters must be at least 21 years old.';
  end if;
  if p_date_of_birth < current_date - interval '120 years' then
    raise exception 'Check the four-digit birth year and try again.';
  end if;
  if v_phone is not null and v_phone_normalized is null then
    raise exception 'Enter a valid 10-digit US mobile number.';
  end if;
  if v_intended_use is null or char_length(v_intended_use) not between 3 and 500 then
    raise exception 'Describe what you intend to use the vehicle for.';
  end if;

  select *
    into v_profile
    from public.profiles
    where id = v_user_id
    for update;

  if found then
    v_saved_phone_normalized := public.rentmect_normalize_phone(v_profile.phone);
    v_phone_changed := v_saved_phone_normalized is distinct from v_phone_normalized;
    select coalesce(v_profile.phone_verified, false) and exists (
      select 1
      from public.rentals rental
      where rental.user_id = v_user_id
        and lower(coalesce(rental.status, '')) in (
          'approved',
          'ready_for_pickup',
          'active',
          'overdue',
          'return_initiated'
        )
    ) into v_phone_locked;

    if v_phone_changed and v_phone_locked then
      raise exception 'Your verified phone number is locked while an approved rental is active. Contact Rent Me CT if it must be changed.';
    end if;

    v_identity_details_differ :=
      coalesce(lower(regexp_replace(trim(v_profile.full_name), '\s+', ' ', 'g')), '')
        is distinct from coalesce(lower(v_full_name), '')
      or v_profile.date_of_birth is distinct from p_date_of_birth;
    v_existing_identity_error := lower(coalesce(v_profile.identity_verification_error_code, ''));
    v_identity_attempted :=
      v_profile.stripe_identity_verification_session_id is not null
      or v_profile.identity_verified_at is not null
      or lower(coalesce(v_profile.identity_verification_status, 'unverified')) <> 'unverified'
      or v_existing_identity_error in (
        'name_mismatch',
        'date_of_birth_mismatch',
        'identity_details_mismatch'
      );
    v_identity_changed := v_identity_details_differ and v_identity_attempted;

    update public.profiles
      set email = coalesce(v_email, email),
          full_name = v_full_name,
          phone = case when v_phone_changed then v_phone else phone end,
          address = coalesce(nullif(trim(p_address), ''), address),
          date_of_birth = p_date_of_birth,
          intended_vehicle_use = v_intended_use,
          phone_verified = case when v_phone_changed then false else phone_verified end,
          phone_verified_at = case when v_phone_changed then null else phone_verified_at end,
          phone_verification_method = case when v_phone_changed then null else phone_verification_method end,
          phone_verification_updated_at = case when v_phone_changed then null else phone_verification_updated_at end,
          stripe_identity_verification_session_id = case when v_identity_changed then null else stripe_identity_verification_session_id end,
          identity_verification_status = case
            when v_identity_changed and v_existing_identity_error in (
              'name_mismatch',
              'date_of_birth_mismatch',
              'identity_details_mismatch'
            ) then 'requires_input'
            when v_identity_changed then 'unverified'
            else identity_verification_status
          end,
          identity_verified_at = case when v_identity_changed then null else identity_verified_at end,
          identity_verification_error_code = case
            when not v_identity_changed then identity_verification_error_code
            when v_existing_identity_error in (
              'name_mismatch',
              'date_of_birth_mismatch',
              'identity_details_mismatch'
            ) then v_existing_identity_error
            else 'profile_details_changed'
          end,
          identity_verification_updated_at = case when v_identity_changed then now() else identity_verification_updated_at end
      where id = v_user_id
      returning * into v_profile;
  else
    insert into public.profiles (
      id, email, full_name, phone, address, date_of_birth,
      intended_vehicle_use, phone_verified
    ) values (
      v_user_id, v_email, v_full_name, v_phone, null, p_date_of_birth,
      v_intended_use, false
    ) returning * into v_profile;
  end if;

  return v_profile;
end;
$$;

comment on function public.save_customer_profile_contact_details(text, text, text, date, text)
  is 'Saves authenticated renter contact details, normalizes phone changes, and locks only verified active-rental phone numbers.';
