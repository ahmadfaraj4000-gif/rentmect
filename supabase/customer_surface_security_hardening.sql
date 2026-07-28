-- Harden website pending bookings plus customer document/message writes.
-- Run after production_rls_policies.sql and rental_workflow_security_hardening.sql.

create or replace function public.create_website_pending_booking(
  p_pickup_date date,
  p_return_date date,
  p_pickup_time text default '9:00 AM',
  p_return_time text default '9:00 AM',
  p_vehicle_id uuid default null,
  p_selected_vehicle_name text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
begin
  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;

  if p_return_date <= p_pickup_date then
    raise exception 'Return date must be after pickup date.';
  end if;

  insert into public.pending_bookings (
    pickup_date,
    return_date,
    pickup_time,
    return_time,
    vehicle_id,
    selected_vehicle_name,
    status,
    source
  )
  values (
    p_pickup_date,
    p_return_date,
    coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
    coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
    p_vehicle_id,
    nullif(trim(p_selected_vehicle_name), ''),
    'pending',
    'website'
  )
  returning id into v_booking_id;

  return v_booking_id;
end;
$$;

revoke all on function public.create_website_pending_booking(date, date, text, text, uuid, text) from public;
grant execute on function public.create_website_pending_booking(date, date, text, text, uuid, text) to anon, authenticated;

create or replace function public.get_website_pending_booking(
  p_booking_id uuid
) returns table (
  id uuid,
  pickup_date date,
  return_date date,
  pickup_time text,
  return_time text,
  vehicle_id uuid,
  selected_vehicle_name text
)
language sql
security definer
set search_path = public
as $$
  select
    pending_bookings.id,
    pending_bookings.pickup_date,
    pending_bookings.return_date,
    pending_bookings.pickup_time,
    pending_bookings.return_time,
    pending_bookings.vehicle_id,
    pending_bookings.selected_vehicle_name
  from public.pending_bookings
  where pending_bookings.id = p_booking_id
    and pending_bookings.source = 'website'
    and coalesce(lower(pending_bookings.status), 'pending') = 'pending';
$$;

revoke all on function public.get_website_pending_booking(uuid) from public;
grant execute on function public.get_website_pending_booking(uuid) to anon, authenticated;

create or replace function public.claim_customer_pending_booking(
  p_booking_id uuid,
  p_vehicle_id uuid default null,
  p_customer_phone text default null
) returns public.pending_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_booking public.pending_bookings%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to claim a booking.';
  end if;

  select *
    into v_booking
    from public.pending_bookings
    where id = p_booking_id
      and source = 'website'
    for update;

  if not found then
    raise exception 'Pending booking not found.';
  end if;

  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;

  if coalesce(lower(v_booking.status), 'pending') <> 'pending' then
    return v_booking;
  end if;

  update public.pending_bookings
    set user_id = v_user_id,
        customer_email = coalesce(v_email, customer_email),
        customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
        vehicle_id = coalesce(p_vehicle_id, vehicle_id),
        updated_at = now()
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.claim_customer_pending_booking(uuid, uuid, text) from public;
grant execute on function public.claim_customer_pending_booking(uuid, uuid, text) to authenticated;

create or replace function public.convert_customer_pending_booking(
  p_booking_id uuid,
  p_vehicle_id uuid default null,
  p_customer_phone text default null
) returns public.pending_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := nullif(auth.jwt() ->> 'email', '');
  v_booking public.pending_bookings%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to convert a booking.';
  end if;

  select *
    into v_booking
    from public.pending_bookings
    where id = p_booking_id
      and source = 'website'
    for update;

  if not found then
    raise exception 'Pending booking not found.';
  end if;

  if v_booking.user_id is not null and v_booking.user_id <> v_user_id then
    raise exception 'Pending booking has already been claimed.';
  end if;

  update public.pending_bookings
    set user_id = v_user_id,
        customer_email = coalesce(v_email, customer_email),
        customer_phone = coalesce(nullif(trim(p_customer_phone), ''), customer_phone),
        vehicle_id = coalesce(p_vehicle_id, vehicle_id),
        status = 'converted',
        updated_at = now()
    where id = p_booking_id
    returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.convert_customer_pending_booking(uuid, uuid, text) from public;
grant execute on function public.convert_customer_pending_booking(uuid, uuid, text) to authenticated;

create or replace function public.replace_customer_rental_document(
  p_document_id uuid,
  p_file_path text
) returns public.rental_documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_document public.rental_documents%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to replace a document.';
  end if;

  if nullif(trim(p_file_path), '') is null then
    raise exception 'Document file path is required.';
  end if;

  select *
    into v_document
    from public.rental_documents
    where id = p_document_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Document not found.';
  end if;

  update public.rental_documents
    set file_path = trim(p_file_path),
        status = 'pending_review'
    where id = p_document_id
    returning * into v_document;

  return v_document;
end;
$$;

revoke all on function public.replace_customer_rental_document(uuid, text) from public;
grant execute on function public.replace_customer_rental_document(uuid, text) to authenticated;

drop policy if exists "Pending bookings can be created from website" on public.pending_bookings;
drop policy if exists "Pending bookings are editable by owner or admins" on public.pending_bookings;

drop policy if exists "Admins can insert pending bookings" on public.pending_bookings;
create policy "Admins can insert pending bookings"
  on public.pending_bookings
  for insert
  to authenticated
  with check (public.is_admin());

drop policy if exists "Admins can update pending bookings" on public.pending_bookings;
create policy "Admins can update pending bookings"
  on public.pending_bookings
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Customers can insert their rental document rows" on public.rental_documents;
create policy "Customers can insert their rental document rows"
  on public.rental_documents
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and document_type in ('license', 'insurance')
    and status = 'pending_review'
    and exists (
      select 1
      from public.rentals
      where rentals.id = rental_documents.rental_id
        and rentals.user_id = auth.uid()
    )
  );

drop policy if exists "Customers can replace their rental document rows" on public.rental_documents;

drop policy if exists "Customers and admins can send rental messages" on public.rental_messages;
create policy "Customers can send rental messages"
  on public.rental_messages
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and sender_role = 'client'
    and read_by_admin = false
    and read_by_client = true
    and (
      rental_id is null
      or exists (
        select 1
        from public.rentals
        where rentals.id = rental_messages.rental_id
          and rentals.user_id = auth.uid()
      )
    )
  );

drop policy if exists "Customers can update their message read state" on public.rental_messages;
