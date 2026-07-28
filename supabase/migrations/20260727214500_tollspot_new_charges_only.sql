-- Activate TollSpot billing prospectively. Transactions already imported
-- before fleet VIN/plate activation remain in the audit trail but can never
-- become customer charges.

alter table public.billing_automation_settings
  add column if not exists tollspot_charge_start_at timestamptz;

update public.billing_automation_settings
set tollspot_charge_start_at = coalesce(tollspot_charge_start_at, now()),
    updated_at = now()
where id = true;

alter table public.billing_automation_settings
  alter column tollspot_charge_start_at set default now(),
  alter column tollspot_charge_start_at set not null;

create or replace function public.enforce_tollspot_charge_start()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_at timestamptz;
begin
  select tollspot_charge_start_at
  into v_start_at
  from public.billing_automation_settings
  where id = true;

  if v_start_at is not null
     and new.occurred_at < v_start_at
     and coalesce(new.status, 'received') not in ('charge_created', 'paid') then
    new.status := 'ignored';
    new.rental_id := null;
    new.rental_charge_item_id := null;
    new.ignored_reason := 'Transaction predates TollSpot customer-charge activation.';
    new.review_reason := null;
  end if;
  return new;
end;
$$;

drop trigger if exists tollspot_enforce_charge_start
on public.tollspot_transactions;
create trigger tollspot_enforce_charge_start
before insert or update of occurred_at, status
on public.tollspot_transactions
for each row execute function public.enforce_tollspot_charge_start();

update public.tollspot_transactions
set status = 'ignored',
    rental_id = null,
    rental_charge_item_id = null,
    ignored_reason = 'Transaction predates TollSpot customer-charge activation.',
    review_reason = null,
    updated_at = now()
where occurred_at < (
    select tollspot_charge_start_at
    from public.billing_automation_settings
    where id = true
  )
  and status not in ('charge_created', 'paid');

comment on column public.billing_automation_settings.tollspot_charge_start_at is
  'Only TollSpot transactions incurred at or after this instant may become customer charges.';
