-- Close legacy anonymous access to customer booking and rental records.
-- Public availability is served through restricted RPCs, not direct table reads.

alter table public.rentals enable row level security;
alter table public.pending_bookings enable row level security;

revoke all on table public.rentals from public, anon;
revoke all on table public.pending_bookings from public, anon;

grant select, insert, update, delete on table public.rentals to authenticated;
grant select, insert, update, delete on table public.pending_bookings to authenticated;

do $$
declare
  policy_record record;
begin
  for policy_record in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('rentals', 'pending_bookings')
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      policy_record.policyname,
      policy_record.schemaname,
      policy_record.tablename
    );
  end loop;
end;
$$;

create policy "Customers can read their rentals"
  on public.rentals
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy "Admins can create rentals"
  on public.rentals
  for insert
  to authenticated
  with check (public.is_admin());

create policy "Admins can update rentals"
  on public.rentals
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "Admins can delete rentals"
  on public.rentals
  for delete
  to authenticated
  using (public.is_admin());

create policy "Pending bookings are visible to owner or admins"
  on public.pending_bookings
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy "Admins can insert pending bookings"
  on public.pending_bookings
  for insert
  to authenticated
  with check (public.is_admin());

create policy "Admins can update pending bookings"
  on public.pending_bookings
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "Admins can delete pending bookings"
  on public.pending_bookings
  for delete
  to authenticated
  using (public.is_admin());
