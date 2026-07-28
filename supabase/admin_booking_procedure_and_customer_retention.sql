-- Admin-assisted booking procedure and explicit Auth-deletion retention.
-- Run after admin_manual_booking.sql, rental document policies, and Stripe migrations.
--
-- Rentals are financial/operational records and intentionally survive deletion
-- of a Supabase Auth login. Snapshot fields keep the historical record legible,
-- while customer_auth_deleted_at prevents an orphan from looking like a live user.

alter table public.rentals
  add column if not exists customer_name_snapshot text,
  add column if not exists customer_email_snapshot text,
  add column if not exists customer_phone_snapshot text,
  add column if not exists customer_auth_deleted_at timestamptz;

update public.rentals r
set customer_name_snapshot = coalesce(r.customer_name_snapshot, p.full_name),
    customer_email_snapshot = coalesce(r.customer_email_snapshot, p.email),
    customer_phone_snapshot = coalesce(r.customer_phone_snapshot, p.phone)
from public.profiles p
where p.id = r.user_id
  and (
    r.customer_name_snapshot is null or
    r.customer_email_snapshot is null or
    r.customer_phone_snapshot is null
  );

-- Mark accounts that were deleted before this migration existed.
update public.rentals r
set customer_auth_deleted_at = coalesce(r.customer_auth_deleted_at, now())
where r.user_id is not null
  and not exists (select 1 from auth.users u where u.id = r.user_id);

create or replace function public.snapshot_rental_customer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
begin
  select * into v_profile from public.profiles where id = new.user_id;
  new.customer_name_snapshot := coalesce(new.customer_name_snapshot, v_profile.full_name);
  new.customer_email_snapshot := coalesce(new.customer_email_snapshot, v_profile.email);
  new.customer_phone_snapshot := coalesce(new.customer_phone_snapshot, v_profile.phone);
  return new;
end;
$$;

drop trigger if exists snapshot_rental_customer_on_write on public.rentals;
create trigger snapshot_rental_customer_on_write
before insert or update of user_id on public.rentals
for each row execute function public.snapshot_rental_customer();

create or replace function public.mark_rentals_for_deleted_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
begin
  select * into v_profile from public.profiles where id = old.id;
  update public.rentals
  set customer_name_snapshot = coalesce(customer_name_snapshot, v_profile.full_name, old.raw_user_meta_data ->> 'full_name'),
      customer_email_snapshot = coalesce(customer_email_snapshot, v_profile.email, old.email),
      customer_phone_snapshot = coalesce(customer_phone_snapshot, v_profile.phone, old.phone),
      customer_auth_deleted_at = coalesce(customer_auth_deleted_at, now())
  where user_id = old.id;
  return old;
end;
$$;

drop trigger if exists mark_rentals_before_auth_user_delete on auth.users;
create trigger mark_rentals_before_auth_user_delete
before delete on auth.users
for each row execute function public.mark_rentals_for_deleted_auth_user();

-- Admin-assisted uploads use a customer-scoped private path. Customers can still
-- read the uploaded object because the first folder is their Auth user id.
drop policy if exists "Admins can upload rental documents" on storage.objects;
create policy "Admins can upload rental documents"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'rental-documents'
  and public.is_admin()
  and exists (
    select 1 from public.rentals r
    where r.user_id::text = (storage.foldername(name))[1]
      and r.customer_auth_deleted_at is null
  )
);

drop policy if exists "Admins can update rental documents" on storage.objects;
create policy "Admins can update rental documents"
on storage.objects for update to authenticated
using (bucket_id = 'rental-documents' and public.is_admin())
with check (bucket_id = 'rental-documents' and public.is_admin());

drop policy if exists "Admins can delete rental documents" on storage.objects;
create policy "Admins can delete rental documents"
on storage.objects for delete to authenticated
using (bucket_id = 'rental-documents' and public.is_admin());

create index if not exists rentals_customer_auth_deleted_at_idx
  on public.rentals (customer_auth_deleted_at)
  where customer_auth_deleted_at is not null;

comment on column public.rentals.customer_auth_deleted_at is
  'Set when the Supabase Auth login is deleted. Rental remains for accounting, legal, and operational audit history.';
