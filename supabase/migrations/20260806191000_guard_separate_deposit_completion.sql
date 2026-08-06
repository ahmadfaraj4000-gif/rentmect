begin;

-- Prevent an admin from recording the same security deposit twice. A full
-- external payment completes both payment and deposit; Stripe completes the
-- deposit from its webhook. Before payment, the only standalone decision is a
-- documented management waiver.
create or replace function public.guard_admin_deposit_step_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.step_key = 'deposit'
     and new.completion_source = 'admin_deposit_collected'
     and not exists (
       select 1 from public.rentals rental
       where rental.id = new.rental_id
         and lower(coalesce(rental.payment_status, 'pending')) = 'paid'
     ) then
    raise exception 'Record the completed payment first. A paid Stripe or external payment completes the deposit automatically.';
  end if;
  return new;
end;
$$;

drop trigger if exists rental_step_completion_deposit_guard on public.rental_step_completions;
create trigger rental_step_completion_deposit_guard
before insert or update on public.rental_step_completions
for each row execute function public.guard_admin_deposit_step_completion();

commit;
