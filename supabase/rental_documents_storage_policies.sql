-- Storage policies for customer rental document uploads/replacements.
-- Run this once in Supabase SQL editor if document upload/replace hits RLS errors.

insert into storage.buckets (id, name, public)
values ('rental-documents', 'rental-documents', false)
on conflict (id) do nothing;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Customers can upload their rental documents'
  ) then
    create policy "Customers can upload their rental documents"
      on storage.objects
      for insert
      to authenticated
      with check (
        bucket_id = 'rental-documents'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Customers can replace their rental documents'
  ) then
    create policy "Customers can replace their rental documents"
      on storage.objects
      for update
      to authenticated
      using (
        bucket_id = 'rental-documents'
        and (storage.foldername(name))[1] = auth.uid()::text
      )
      with check (
        bucket_id = 'rental-documents'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Customers can read their rental documents'
  ) then
    create policy "Customers can read their rental documents"
      on storage.objects
      for select
      to authenticated
      using (
        bucket_id = 'rental-documents'
        and (storage.foldername(name))[1] = auth.uid()::text
      );
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'Admins can read rental documents'
  ) then
    create policy "Admins can read rental documents"
      on storage.objects
      for select
      to authenticated
      using (
        bucket_id = 'rental-documents'
        and exists (
          select 1
          from public.profiles
          where profiles.id = auth.uid()
            and profiles.role = 'admin'
        )
      );
  end if;
end $$;
