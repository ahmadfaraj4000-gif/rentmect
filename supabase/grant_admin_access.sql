-- Run this in the Supabase SQL Editor to give a signed-up user
-- access to the admin portal. Replace the email below if needed.
--
-- This uses auth.users as the source of truth so it updates the profile row
-- for the exact login account, and creates the profile row if it is missing.

insert into public.profiles (id, email, role)
select id, email, 'admin'
from auth.users
where lower(email) = lower('anconamgt@aol.com')
on conflict (id) do update
set email = excluded.email,
    role = 'admin';

-- Confirm it worked. You should see role = admin.
select profiles.id, profiles.email, profiles.role
from public.profiles
join auth.users on auth.users.id = profiles.id
where lower(auth.users.email) = lower('anconamgt@aol.com');
