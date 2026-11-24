begin;

-- Pin these privileges to the two existing staff identities.
create table public.rental_operations_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  staff_name text not null unique
);
alter table public.rental_operations_staff enable row level security;
revoke all on public.rental_operations_staff from public, anon, authenticated;
insert into public.rental_operations_staff (user_id, staff_name)
select u.id, names.staff_name from auth.users u join public.profiles p on p.id = u.id
join (values ('anconamgt@aol.com','Ancona'),('jennifer@rentmect.com','Jennifer')) names(email,staff_name)
on lower(u.email) = names.email where p.role = 'admin';
do $$ begin
  if (select count(*) from public.rental_operations_staff) <> 2 then
    raise exception 'Verify both rental operations staff logins before installation.';
  end if;
end $$;

create function public.rental_operations_staff_name() returns text
language sql stable security definer set search_path = '' as $$
  select s.staff_name from public.rental_operations_staff s
  join public.profiles p on p.id = s.user_id
  where s.user_id = (select auth.uid()) and p.role = 'admin'
$$;
revoke all on function public.rental_operations_staff_name() from public, anon;
grant execute on function public.rental_operations_staff_name() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('rental-inspections','rental-inspections',false,20971520,
  array['image/jpeg','image/png','image/webp','image/heic','image/heif']);

create policy rental_inspection_photo_read on storage.objects for select to authenticated
using (bucket_id = 'rental-inspections' and (select public.rental_operations_staff_name()) is not null);
create policy rental_inspection_photo_upload on storage.objects for insert to authenticated
with check (bucket_id = 'rental-inspections'
  and split_part(name,'/',2) in ('pickup','return')
  and name ~ '^[0-9a-f-]{36}/(pickup|return)/(Ancona|Jennifer)-[0-9a-f-]{36}\.(jpg|png|webp|heic|heif)$'
  and split_part(split_part(name,'/',3),'-',1) = (select public.rental_operations_staff_name())
  and exists (select 1 from public.rentals r where r.id::text = split_part(name,'/',1)));
commit;
