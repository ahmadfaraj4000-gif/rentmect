begin;

-- Refund timing is measured from physical dropoff (confirmed by inspection),
-- never from when an administrator happens to save Billing Automation settings.
create or replace function public.rentmect_deposit_returned_at(p_rental_id uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select coalesce(r.return_initiated_at, r.inspection_completed_at,
    (select min(i.created_at) from public.rental_return_inspections i where i.rental_id = r.id))
  from public.rentals r where r.id = p_rental_id and r.status = 'completed';
$$;
revoke all on function public.rentmect_deposit_returned_at(uuid) from public, anon, authenticated;
grant execute on function public.rentmect_deposit_returned_at(uuid) to service_role;

create or replace function public.schedule_rentmect_deposit_release()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_decision text;
  v_enabled boolean := true;
  v_delay integer := 30;
  v_returned_at timestamptz;
begin
  if lower(coalesce(new.deposit_status, '')) not in ('held', 'adjustment_refund_due') then
    new.deposit_release_due_at := null;
    return new;
  end if;
  select automatic_deposit_release_enabled, deposit_release_delay_days into v_enabled, v_delay
    from public.billing_automation_settings where id = true;
  if new.status = 'completed' and lower(coalesce(new.payment_provider, '')) = 'stripe'
     and old.status is distinct from 'completed' then
    select i.deposit_decision into v_decision from public.rental_return_inspections i
      where i.rental_id = new.id order by i.created_at desc limit 1;
    if coalesce(v_decision, 'release') = 'release' and coalesce(v_enabled, true) then
      v_returned_at := coalesce(new.return_initiated_at, new.inspection_completed_at,
        (select min(i.created_at) from public.rental_return_inspections i where i.rental_id = new.id), now());
      new.deposit_release_due_at := ((v_returned_at at time zone 'America/New_York')
        + make_interval(days => coalesce(v_delay, 30))) at time zone 'America/New_York';
      new.deposit_release_reason := format(
        'Automatic refund scheduled %s calendar days after recorded return; admin may refund earlier. Unresolved charges require review before the deadline.', coalesce(v_delay, 30));
      new.deposit_release_error := null;
    else
      new.deposit_release_due_at := null;
      new.deposit_release_reason := case when not coalesce(v_enabled, true)
        then 'Automatic deposit release is disabled in Billing Automation settings.'
        else 'Held by return inspection decision; resolve and itemize deductions before the 30-day deadline.' end;
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.apply_billing_automation_to_held_deposits()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.automatic_deposit_release_enabled then
    update public.rentals r
      set deposit_release_due_at = ((public.rentmect_deposit_returned_at(r.id) at time zone 'America/New_York')
            + make_interval(days => new.deposit_release_delay_days)) at time zone 'America/New_York',
          deposit_release_reason = format(
            'Automatic refund scheduled %s calendar days after recorded return; admin may refund earlier. Unresolved charges require review before the deadline.', new.deposit_release_delay_days)
      where r.status = 'completed' and lower(coalesce(r.payment_provider, '')) = 'stripe'
        and r.deposit_status in ('held', 'adjustment_refund_due')
        -- Failed/blocked refunds require explicit review; do not retry them by saving settings.
        and r.deposit_release_error is null
        and public.rentmect_deposit_returned_at(r.id) is not null
        and coalesce((select i.deposit_decision from public.rental_return_inspections i
          where i.rental_id = r.id order by i.created_at desc limit 1), 'release') = 'release';
    -- A legacy seven-day deadline without any return evidence cannot safely
    -- be reused or converted into an invented physical-return timestamp.
    update public.rentals r set deposit_release_due_at = null,
      deposit_release_reason = 'Recorded return time is missing. Admin must verify return and refund deadline.'
      where r.status = 'completed' and lower(coalesce(r.payment_provider, '')) = 'stripe'
        and r.deposit_status in ('held', 'adjustment_refund_due')
        and r.deposit_release_due_at is not null
        and public.rentmect_deposit_returned_at(r.id) is null;
  else
    update public.rentals r set deposit_release_due_at = null,
      deposit_release_reason = 'Automatic deposit release is disabled in Billing Automation settings.'
      where r.deposit_status in ('held', 'adjustment_refund_due') and r.deposit_release_due_at is not null;
  end if;
  return new;
end;
$$;

alter table public.billing_automation_settings alter column deposit_release_delay_days set default 30;
-- Existing queued refunds move to return + 30 days; released/pending refunds,
-- inspection holds, external deposits and failed refunds remain untouched.
insert into public.billing_automation_settings (id, automatic_deposit_release_enabled, deposit_release_delay_days)
values (true, true, 30)
on conflict (id) do update set automatic_deposit_release_enabled = true, deposit_release_delay_days = 30;

commit;
