begin;

create table if not exists public.tollspot_transponder_mappings (
  id uuid primary key default gen_random_uuid(),
  transponder_number text not null unique,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  tollspot_vehicle_id text not null,
  first_seen_at timestamptz,
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz not null default now(),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tollspot_transponder_number_present check (length(trim(transponder_number)) > 0)
);

alter table public.tollspot_transponder_mappings enable row level security;
revoke all on public.tollspot_transponder_mappings from public, anon, authenticated;
grant all on public.tollspot_transponder_mappings to service_role;

-- Seed only transponders that historical provider data already tied to exactly
-- one local fleet vehicle. Ambiguous or anonymous transponders remain blocked.
insert into public.tollspot_transponder_mappings (
  transponder_number, vehicle_id, tollspot_vehicle_id, first_seen_at
)
select
  regexp_replace(transaction.transponder_number, '[^0-9A-Za-z]', '', 'g'),
  min(transaction.vehicle_id::text)::uuid,
  min(mapping.tollspot_vehicle_id),
  min(transaction.occurred_at)
from public.tollspot_transactions transaction
join public.tollspot_vehicle_mappings mapping
  on mapping.vehicle_id = transaction.vehicle_id
 and mapping.active
where nullif(regexp_replace(transaction.transponder_number, '[^0-9A-Za-z]', '', 'g'), '') is not null
  and transaction.vehicle_id is not null
group by regexp_replace(transaction.transponder_number, '[^0-9A-Za-z]', '', 'g')
having count(distinct transaction.vehicle_id) = 1
on conflict (transponder_number) do nothing;

create or replace function public.service_apply_tollspot_transponder_mappings(
  p_transaction_ids uuid[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  with resolved as (
    select transaction.id, mapping.tollspot_vehicle_id
    from public.tollspot_transactions transaction
    join public.tollspot_transponder_mappings mapping
      on mapping.active
     and mapping.transponder_number = regexp_replace(
       coalesce(transaction.transponder_number, ''), '[^0-9A-Za-z]', '', 'g'
     )
    where transaction.id = any(coalesce(p_transaction_ids, '{}'::uuid[]))
      and transaction.status not in ('charge_created', 'paid', 'ignored')
      and (mapping.first_seen_at is null or transaction.occurred_at >= mapping.first_seen_at)
  )
  update public.tollspot_transactions transaction
  set tollspot_vehicle_id = resolved.tollspot_vehicle_id,
      updated_at = now()
  from resolved
  where transaction.id = resolved.id
    and transaction.tollspot_vehicle_id is distinct from resolved.tollspot_vehicle_id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.service_apply_tollspot_transponder_mappings(uuid[])
  from public, anon, authenticated;
grant execute on function public.service_apply_tollspot_transponder_mappings(uuid[])
  to service_role;

-- Show the whole toll queue, including anonymous provider rows, with every
-- available identifier and the resolved local vehicle/customer when present.
drop view if exists public.admin_tollspot_transactions;
create or replace view public.admin_tollspot_transactions
with (security_invoker = true)
as
select
  transaction.id,
  transaction.tollspot_transaction_id,
  transaction.tollspot_vehicle_id,
  transaction.vehicle_id,
  vehicle.name as vehicle_name,
  vehicle.plate_number as vehicle_plate_number,
  transaction.rental_id,
  rental.pickup_date,
  rental.return_date,
  customer.full_name as customer_name,
  customer.email as customer_email,
  transaction.occurred_at,
  transaction.posted_at,
  transaction.entry_at,
  transaction.entry_location,
  transaction.exit_location,
  transaction.agency,
  transaction.transaction_type,
  transaction.license_plate,
  transaction.license_plate_state,
  transaction.license_plate_country,
  transaction.transponder_number,
  case
    when nullif(transaction.transponder_number, '') is null then null
    else repeat('•', greatest(length(transaction.transponder_number) - 4, 0))
      || right(transaction.transponder_number, 4)
  end as masked_transponder,
  transaction.toll_amount,
  transaction.admin_fee,
  transaction.total_amount,
  transaction.currency,
  transaction.status,
  transaction.match_method,
  transaction.match_candidate_count,
  transaction.review_reason,
  transaction.ignored_reason,
  transaction.rental_charge_item_id,
  transaction.reviewed_by,
  transaction.reviewed_at,
  transaction.created_at,
  transaction.updated_at
from public.tollspot_transactions transaction
left join public.vehicles vehicle on vehicle.id = transaction.vehicle_id
left join public.rentals rental on rental.id = transaction.rental_id
left join public.profiles customer on customer.id = rental.user_id
where upper(coalesce(transaction.transaction_type, 'TOLLS')) = 'TOLLS';

grant select on public.admin_tollspot_transactions to authenticated;

comment on view public.admin_tollspot_transactions is
  'Complete admin toll queue with provider identifiers, local vehicle, rental, customer, and unmatched rows visible for safe review.';

notify pgrst, 'reload schema';

commit;
