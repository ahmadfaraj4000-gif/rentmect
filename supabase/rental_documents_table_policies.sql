-- RLS policies for rental_documents table.
-- Run this if document upload/replace succeeds in storage but the app gets:
-- "Cannot coerce the result to a single JSON object" or RLS errors.

alter table public.rental_documents enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'rental_documents'
      and policyname = 'Customers can read their rental document rows'
  ) then
    create policy "Customers can read their rental document rows"
      on public.rental_documents
      for select
      to authenticated
      using (user_id = auth.uid());
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'rental_documents'
      and policyname = 'Customers can insert their rental document rows'
  ) then
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
  end if;

  -- Customers replace file paths through replace_customer_rental_document().
  -- Do not re-add a direct document update policy here.
  drop policy if exists "Customers can replace their rental document rows"
    on public.rental_documents;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'rental_documents'
      and policyname = 'Admins can manage rental document rows'
  ) then
    create policy "Admins can manage rental document rows"
      on public.rental_documents
      for all
      to authenticated
      using (
        exists (
          select 1
          from public.profiles
          where profiles.id = auth.uid()
            and profiles.role = 'admin'
        )
      )
      with check (
        exists (
          select 1
          from public.profiles
          where profiles.id = auth.uid()
            and profiles.role = 'admin'
        )
      );
  end if;
end $$;
