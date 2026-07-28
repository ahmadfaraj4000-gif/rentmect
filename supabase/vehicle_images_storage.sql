-- Public, performance-capped vehicle photos uploaded by authenticated admins.
-- Run after production_rls_policies.sql so public.is_admin() is available.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vehicle-images', 'vehicle-images', true, 460800, array['image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Admins can upload vehicle images" on storage.objects;
create policy "Admins can upload vehicle images"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'vehicle-images'
  and public.is_admin()
);

drop policy if exists "Admins can update vehicle images" on storage.objects;
create policy "Admins can update vehicle images"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'vehicle-images'
  and public.is_admin()
)
with check (
  bucket_id = 'vehicle-images'
  and public.is_admin()
);

drop policy if exists "Admins can delete vehicle images" on storage.objects;
create policy "Admins can delete vehicle images"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'vehicle-images'
  and public.is_admin()
);
