create policy rental_inspection_photo_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'rental-inspections'
  and name ~ '^[0-9a-f-]{36}/(pickup|return)/(Ancona|Jennifer)-[0-9a-f-]{36}\.(jpg|png|webp|heic|heif)$'
  and (select public.rental_operations_staff_name()) is not null
);
