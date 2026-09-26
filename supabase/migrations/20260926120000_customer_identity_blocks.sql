begin;

-- Keep blocked identities even when the originating account is deleted.
-- No FK to auth.users/profiles: deletion must never clear a customer block.
create table public.customer_identity_blocks (
  source_user_id uuid not null,
  identity_type text not null check (identity_type in ('email', 'phone')),
  identity_value text not null,
  created_at timestamptz not null default now(),
  primary key (source_user_id, identity_type, identity_value)
);
create index customer_identity_blocks_lookup on public.customer_identity_blocks(identity_type, identity_value);
alter table public.customer_identity_blocks enable row level security;
revoke all on public.customer_identity_blocks from public, anon, authenticated;

create function public.rentmect_block_email(p_value text) returns text
language sql immutable set search_path = public
as $$ select nullif(lower(btrim(p_value)), ''); $$;
create function public.rentmect_block_phone(p_value text) returns text
language sql immutable set search_path = public
as $$
  select case when length(digits) = 10 then '1' || digits
    when length(digits) = 11 and left(digits, 1) = '1' then digits
    else nullif(digits, '') end
  from (select regexp_replace(coalesce(p_value, ''), '[^0-9]', '', 'g') digits) normalized;
$$;

create function public.rentmect_customer_is_blocked(p_user_id uuid, p_email text default null, p_phone text default null)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles p where p.id = p_user_id
    and (coalesce(p.blocked_customer, false) or p.customer_status = 'blocked'))
  or exists (
    select 1 from public.customer_identity_blocks b
    where b.source_user_id = p_user_id
      or (b.identity_type = 'email' and b.identity_value = public.rentmect_block_email(p_email))
      or (b.identity_type = 'phone' and b.identity_value = public.rentmect_block_phone(p_phone))
      or exists (select 1 from public.profiles p where p.id = p_user_id and (
        (b.identity_type = 'email' and b.identity_value = public.rentmect_block_email(p.email)) or
        (b.identity_type = 'phone' and b.identity_value = public.rentmect_block_phone(p.phone))))
      or exists (select 1 from auth.users u where u.id = p_user_id and (
        (b.identity_type = 'email' and b.identity_value = public.rentmect_block_email(u.email)) or
        (b.identity_type = 'phone' and b.identity_value = public.rentmect_block_phone(u.phone))))
  );
$$;
revoke all on function public.rentmect_customer_is_blocked(uuid,text,text) from public, anon, authenticated;

create function public.rentmect_sync_customer_block() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(new.blocked_customer, false) or new.customer_status = 'blocked' then
    insert into public.customer_identity_blocks(source_user_id,identity_type,identity_value)
    select new.id, kind, value from (
      values ('email', public.rentmect_block_email(new.email)),
             ('phone', public.rentmect_block_phone(new.phone)),
             ('email', public.rentmect_block_email(case when tg_op = 'UPDATE' then old.email end)),
             ('phone', public.rentmect_block_phone(case when tg_op = 'UPDATE' then old.phone end))
    ) identities(kind,value) where value is not null on conflict do nothing;
    insert into public.customer_identity_blocks(source_user_id,identity_type,identity_value)
    select new.id, identities.kind, identities.value from auth.users u
    cross join lateral (values ('email',public.rentmect_block_email(u.email)),
      ('phone',public.rentmect_block_phone(u.phone)),
      ('phone',public.rentmect_block_phone(u.raw_user_meta_data->>'phone'))) identities(kind,value)
    where u.id = new.id and identities.value is not null on conflict do nothing;
  elsif tg_op = 'UPDATE' and (coalesce(old.blocked_customer,false) or old.customer_status = 'blocked') then
    delete from public.customer_identity_blocks where source_user_id = new.id;
  end if;
  return new;
end;
$$;
create trigger profiles_sync_customer_block after insert or update of email,phone,blocked_customer,customer_status
on public.profiles for each row execute function public.rentmect_sync_customer_block();

-- Backfill existing blocks without changing profiles or sending notifications.
insert into public.customer_identity_blocks(source_user_id,identity_type,identity_value)
select p.id,i.kind,i.value from public.profiles p left join auth.users u on u.id=p.id
cross join lateral (values ('email',public.rentmect_block_email(p.email)),
  ('phone',public.rentmect_block_phone(p.phone)),('email',public.rentmect_block_email(u.email)),
  ('phone',public.rentmect_block_phone(u.phone)),('phone',public.rentmect_block_phone(u.raw_user_meta_data->>'phone'))) i(kind,value)
where (coalesce(p.blocked_customer,false) or p.customer_status='blocked') and i.value is not null
on conflict do nothing;

create function public.rentmect_guard_blocked_auth_identity() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email
    and new.phone is not distinct from old.phone
    and (new.raw_user_meta_data->>'phone') is not distinct from (old.raw_user_meta_data->>'phone') then
    return new;
  end if;
  if public.rentmect_customer_is_blocked(new.id,new.email,new.phone)
    or public.rentmect_customer_is_blocked(null,null,new.raw_user_meta_data->>'phone') then
    raise exception using errcode='P0001', message='This customer is blocked. Please contact Rent Me CT.';
  end if;
  return new;
end;
$$;
create trigger users_guard_blocked_identity before insert or update of email,phone,raw_user_meta_data
on auth.users for each row execute function public.rentmect_guard_blocked_auth_identity();

create function public.rentmect_guard_blocked_profile() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Only authorized staff or trusted backend operations may change blocking fields.
  if auth.uid() is not null and not coalesce(public.rentmect_has_permission('customer.manage'),false) then
    if (tg_op = 'INSERT' and (coalesce(new.blocked_customer,false) or coalesce(new.customer_status,'good') <> 'good'))
      or (tg_op = 'UPDATE' and (new.blocked_customer is distinct from old.blocked_customer
        or new.customer_status is distinct from old.customer_status
        or new.block_reason is distinct from old.block_reason or new.blocked_at is distinct from old.blocked_at)) then
      raise exception 'Customer management permission is required.';
    end if;
  end if;
  if tg_op = 'INSERT' or new.email is distinct from old.email or new.phone is distinct from old.phone then
    -- Staff may correct a blocked customer's record; the AFTER trigger retains old and new identities.
    if not (tg_op = 'UPDATE' and (coalesce(new.blocked_customer,false) or new.customer_status='blocked')
      and (auth.uid() is null or coalesce(public.rentmect_has_permission('customer.manage'),false)))
      and public.rentmect_customer_is_blocked(new.id,new.email,new.phone) then
      raise exception 'This customer is blocked. Please contact Rent Me CT.';
    end if;
  end if;
  return new;
end;
$$;
create trigger profiles_00_guard_customer_block before insert or update on public.profiles
for each row execute function public.rentmect_guard_blocked_profile();

create or replace function public.admin_set_customer_status(p_user_id uuid,p_customer_status text,p_block_reason text default null)
returns public.profiles language plpgsql security definer set search_path = public
as $$
declare v_profile public.profiles%rowtype;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('customer.manage'),false) then
    raise exception 'Customer management permission is required.';
  end if;
  if p_customer_status is null or p_customer_status not in ('good','review_required','blocked') then
    raise exception 'Invalid customer status.';
  end if;
  update public.profiles set customer_status=p_customer_status, blocked_customer=(p_customer_status='blocked'),
    block_reason=case when p_customer_status='good' then null else nullif(btrim(p_block_reason),'') end,
    blocked_at=case when p_customer_status='blocked' then coalesce(blocked_at,now()) else null end
  where id=p_user_id returning * into v_profile;
  if not found then raise exception 'Customer profile not found.'; end if;
  return v_profile;
end;
$$;
revoke all on function public.admin_set_customer_status(uuid,text,text) from public, anon;
grant execute on function public.admin_set_customer_status(uuid,text,text) to authenticated;

create function public.rentmect_guard_blocked_booking() returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_new jsonb := to_jsonb(new); v_user_id uuid;
begin
  v_user_id := new.user_id;
  if tg_table_name = 'rentals' then
    -- Permit returns, cancellations, refunds, and collection on existing rentals.
    if tg_op = 'UPDATE' and not (
      new.user_id is distinct from old.user_id or new.vehicle_id is distinct from old.vehicle_id
      or new.pickup_date is distinct from old.pickup_date or new.pickup_time is distinct from old.pickup_time
      or public.rentmect_rental_timestamp(new.return_date,new.return_time) > public.rentmect_rental_timestamp(old.return_date,old.return_time)
      or (new.status is distinct from old.status and new.status in ('pending','documents_needed','document_review','approved','ready_for_pickup','active'))
    ) then return new; end if;
  elsif tg_table_name = 'rental_extension_requests' then
    select user_id into v_user_id from public.rentals where id=new.rental_id;
    if tg_op = 'UPDATE' and not (
      new.user_id is distinct from old.user_id or new.rental_id is distinct from old.rental_id
      or new.requested_return_date is distinct from old.requested_return_date
      or new.requested_return_time is distinct from old.requested_return_time
      or new.replacement_vehicle_id is distinct from old.replacement_vehicle_id
      or (new.status is distinct from old.status and new.status in ('pending','approved','activated'))
    ) then return new; end if;
  else
    if tg_op = 'UPDATE' and not (
      new.user_id is distinct from old.user_id or new.customer_email is distinct from old.customer_email
      or new.customer_phone is distinct from old.customer_phone
      or new.pickup_date is distinct from old.pickup_date or new.return_date is distinct from old.return_date
      or new.pickup_time is distinct from old.pickup_time or new.return_time is distinct from old.return_time
      or new.vehicle_id is distinct from old.vehicle_id
      or (new.status is distinct from old.status and new.status in ('pending','claimed','converted'))
    ) then return new; end if;
  end if;
  if public.rentmect_customer_is_blocked(v_user_id,coalesce(v_new->>'customer_email',v_new->>'user_email'),v_new->>'customer_phone')
    or (tg_table_name='rental_extension_requests' and public.rentmect_customer_is_blocked(new.user_id)) then
    raise exception 'This customer is blocked from booking. Please contact Rent Me CT.';
  end if;
  return new;
end;
$$;
create trigger rentals_00_blocked_customer before insert or update on public.rentals
for each row execute function public.rentmect_guard_blocked_booking();
create trigger pending_bookings_00_blocked_customer before insert or update on public.pending_bookings
for each row execute function public.rentmect_guard_blocked_booking();
create trigger rental_extensions_00_blocked_customer before insert or update on public.rental_extension_requests
for each row execute function public.rentmect_guard_blocked_booking();

revoke all on function public.rentmect_sync_customer_block() from public,anon,authenticated;
revoke all on function public.rentmect_guard_blocked_auth_identity() from public,anon,authenticated;
revoke all on function public.rentmect_guard_blocked_profile() from public,anon,authenticated;
revoke all on function public.rentmect_guard_blocked_booking() from public,anon,authenticated;
commit;
