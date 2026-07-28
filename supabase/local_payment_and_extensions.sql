-- Local testing payment simulation and rental extension workflow.
-- This file intentionally does not replace create_rental_with_lock or
-- get_fleet_availability. Extension approval does its own lock and overlap check.

create table if not exists public.rental_extension_requests (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  request_kind text not null default 'same_vehicle_extension',
  replacement_vehicle_id uuid references public.vehicles(id) on delete set null,
  replacement_rental_id uuid references public.rentals(id) on delete set null,
  requested_return_date date not null,
  requested_return_time text not null default '9:00 AM',
  status text not null default 'pending',
  payment_status text not null default 'not_due',
  original_return_date date,
  original_return_time text,
  extension_days integer,
  extension_rental_amount numeric,
  extension_tax_amount numeric,
  extension_deposit_amount numeric not null default 0,
  existing_deposit_held numeric not null default 0,
  replacement_deposit_required numeric not null default 0,
  deposit_carried_amount numeric not null default 0,
  deposit_increase_amount numeric not null default 0,
  deposit_decrease_amount numeric not null default 0,
  extension_total_amount numeric,
  paid_at timestamptz,
  activated_at timestamptz,
  customer_note text,
  admin_note text,
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rental_extension_request_status_check
    check (status in ('pending', 'approved_pending_payment', 'activated', 'rejected', 'cancelled')),
  constraint rental_extension_request_payment_status_check
    check (payment_status in ('not_due', 'pending', 'paid')),
  constraint rental_extension_request_kind_check
    check (request_kind in ('same_vehicle_extension', 'switch_car_continuation'))
);

alter table public.rental_extension_requests
  add column if not exists request_kind text not null default 'same_vehicle_extension',
  add column if not exists replacement_vehicle_id uuid references public.vehicles(id) on delete set null,
  add column if not exists replacement_rental_id uuid references public.rentals(id) on delete set null,
  add column if not exists payment_status text not null default 'not_due',
  add column if not exists original_return_date date,
  add column if not exists original_return_time text,
  add column if not exists extension_days integer,
  add column if not exists extension_rental_amount numeric,
  add column if not exists extension_tax_amount numeric,
  add column if not exists extension_deposit_amount numeric not null default 0,
  add column if not exists existing_deposit_held numeric not null default 0,
  add column if not exists replacement_deposit_required numeric not null default 0,
  add column if not exists deposit_carried_amount numeric not null default 0,
  add column if not exists deposit_increase_amount numeric not null default 0,
  add column if not exists deposit_decrease_amount numeric not null default 0,
  add column if not exists extension_total_amount numeric,
  add column if not exists paid_at timestamptz,
  add column if not exists activated_at timestamptz;

alter table public.rental_extension_requests
  drop constraint if exists rental_extension_request_status_check;

update public.rental_extension_requests
  set status = 'activated',
      payment_status = 'paid',
      paid_at = coalesce(paid_at, decided_at, updated_at),
      activated_at = coalesce(activated_at, decided_at, updated_at)
  where status = 'approved';

alter table public.rental_extension_requests
  add constraint rental_extension_request_status_check
    check (status in ('pending', 'approved_pending_payment', 'activated', 'rejected', 'cancelled'));

alter table public.rental_extension_requests
  drop constraint if exists rental_extension_request_payment_status_check;
alter table public.rental_extension_requests
  add constraint rental_extension_request_payment_status_check
    check (payment_status in ('not_due', 'pending', 'paid'));
alter table public.rental_extension_requests
  drop constraint if exists rental_extension_request_kind_check;
alter table public.rental_extension_requests
  add constraint rental_extension_request_kind_check
    check (request_kind in ('same_vehicle_extension', 'switch_car_continuation'));

drop index if exists public.rental_extension_requests_one_pending_per_rental;
create unique index rental_extension_requests_one_pending_per_rental
  on public.rental_extension_requests (rental_id)
  where status in ('pending', 'approved_pending_payment');

alter table public.rental_extension_requests enable row level security;

drop policy if exists "Customers can read their extension requests" on public.rental_extension_requests;
create policy "Customers can read their extension requests"
  on public.rental_extension_requests
  for select
  to authenticated
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "Admins can manage extension requests" on public.rental_extension_requests;
create policy "Admins can manage extension requests"
  on public.rental_extension_requests
  for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop function if exists public.record_admin_test_rental_payment(uuid);

create or replace function public.record_admin_local_rental_payment(
  p_rental_id uuid
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required to record a local payment.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals cannot be marked paid.';
  end if;

  if coalesce(lower(v_rental.payment_status), 'pending') = 'paid' then
    raise exception 'This rental is already paid.';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = v_rental.user_id and coalesce(p.phone_verified, false)
  ) or not public.rentmect_identity_is_verified(v_rental.user_id) then
    raise exception 'Phone and identity verification must be complete before recording payment.';
  end if;

  if not coalesce(v_rental.agreement_signed, false) then
    raise exception 'The customer must sign the rental agreement before payment can be recorded.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and lower(coalesce(d.document_type, '')) in ('license', 'drivers_license', 'driver_license')
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'An approved driver license is required before recording payment.';
  end if;

  if not exists (
    select 1
    from public.rental_documents d
    where d.user_id = v_rental.user_id
      and d.rental_id = v_rental.id
      and lower(coalesce(d.document_type, '')) = 'insurance'
      and lower(coalesce(d.status, '')) = 'approved'
  ) then
    raise exception 'Approved insurance for this rental is required before recording payment.';
  end if;

  update public.rentals
    set payment_status = 'paid',
        deposit_status = 'held',
        payment_provider = 'local',
        paid_at = coalesce(paid_at, now()),
        deposit_held_amount = greatest(
          coalesce(deposit_held_amount, 0),
          coalesce(security_deposit, 0)
        )
    where id = p_rental_id
    returning * into v_rental;

  update public.rental_charge_items
    set status = 'paid', payment_provider = 'local', paid_at = coalesce(paid_at, now()), updated_at = now()
    where rental_id = v_rental.id and included_in_initial_payment and status <> 'paid';

  perform public.ensure_rental_deposit_allocation(v_rental.id);

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    'admin_local_payment_recorded',
    jsonb_build_object('source', 'record_admin_local_rental_payment')
  );

  return v_rental;
end;
$$;

revoke all on function public.record_admin_local_rental_payment(uuid) from public;
grant execute on function public.record_admin_local_rental_payment(uuid) to authenticated;

create or replace function public.preview_customer_rental_extension(
  p_rental_id uuid,
  p_requested_return_date date,
  p_requested_return_time text default '9:00 AM'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_current_return_at timestamp;
  v_requested_return_at timestamp;
  v_same_vehicle_available boolean;
  v_recommendations jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to preview an extension.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Extensions open only after the rental is active.';
  end if;

  if now() < (
    public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
      at time zone 'America/New_York'
  ) - interval '24 hours' then
    raise exception 'Extension requests open 24 hours before the booked return time.';
  end if;

  if p_requested_return_date is null then
    raise exception 'Requested return date is required.';
  end if;

  select *
    into v_vehicle
    from public.vehicles
    where id = v_rental.vehicle_id;

  if not found then
    raise exception 'Vehicle not found.';
  end if;

  v_current_return_at := public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time);
  v_requested_return_at := public.rentmect_rental_timestamp(
    p_requested_return_date,
    coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time)
  );

  if v_requested_return_at <= v_current_return_at then
    raise exception 'Extension return time must be after the current return time.';
  end if;

  v_same_vehicle_available := not exists (
    select 1
    from public.rentals r
    where r.id <> v_rental.id
      and r.vehicle_id = v_rental.vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and r.pickup_date is not null
      and r.return_date is not null
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        v_requested_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) and not exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = v_rental.vehicle_id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_current_return_at,
        v_requested_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  );

  if not v_same_vehicle_available then
    with alternatives as (
      select
        vehicles.id,
        vehicles.name,
        vehicles.brand,
        vehicles.model,
        vehicles.vehicle_type,
        vehicles.daily_rate,
        vehicles.security_deposit,
        case
          when nullif(lower(vehicles.model), '') = nullif(lower(v_vehicle.model), '') then 0
          when nullif(lower(vehicles.vehicle_type), '') = nullif(lower(v_vehicle.vehicle_type), '') then 1
          when nullif(lower(vehicles.brand), '') = nullif(lower(v_vehicle.brand), '') then 2
          else 3
        end as similarity_rank
      from public.vehicles
      where vehicles.id <> v_rental.vehicle_id
        and coalesce(lower(vehicles.status), 'available') = 'available'
        and not exists (
          select 1
          from public.rentals r
          where r.vehicle_id = vehicles.id
            and coalesce(lower(r.status), '') <> 'cancelled'
            and r.pickup_date is not null
            and r.return_date is not null
            and public.rentmect_periods_overlap(
              v_current_return_at,
              v_requested_return_at + interval '3 hours',
              public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
              public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
            )
        )
        and not exists (
          select 1
          from public.vehicle_availability_blocks b
          where b.vehicle_id = vehicles.id
            and coalesce(b.active, true)
            and coalesce(lower(b.block_type), 'unavailable') <> 'available'
            and public.rentmect_periods_overlap(
              v_current_return_at,
              v_requested_return_at + interval '3 hours',
              public.rentmect_rental_timestamp(b.start_date, b.start_time),
              public.rentmect_rental_timestamp(b.end_date, b.end_time)
            )
        )
      order by similarity_rank, vehicles.daily_rate nulls last, vehicles.name
      limit 4
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', alternatives.id,
          'name', alternatives.name,
          'brand', alternatives.brand,
          'model', alternatives.model,
          'vehicle_type', alternatives.vehicle_type,
          'daily_rate', alternatives.daily_rate,
          'security_deposit', alternatives.security_deposit,
          'similarity_rank', alternatives.similarity_rank
        )
        order by alternatives.similarity_rank, alternatives.daily_rate nulls last, alternatives.name
      ),
      '[]'::jsonb
    )
      into v_recommendations
      from alternatives;
  end if;

  return jsonb_build_object(
    'same_vehicle_available', v_same_vehicle_available,
    'current_vehicle', jsonb_build_object(
      'id', v_vehicle.id,
      'name', v_vehicle.name,
      'brand', v_vehicle.brand,
      'model', v_vehicle.model,
      'vehicle_type', v_vehicle.vehicle_type
    ),
    'requested_return_date', p_requested_return_date,
    'requested_return_time', coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time, '9:00 AM'),
    'recommended_vehicles', v_recommendations
  );
end;
$$;

revoke all on function public.preview_customer_rental_extension(uuid, date, text) from public;
grant execute on function public.preview_customer_rental_extension(uuid, date, text) to authenticated;

create or replace function public.preview_customer_vehicle_switch_continuation(
  p_rental_id uuid,
  p_requested_return_date date,
  p_requested_return_time text default '9:00 AM'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_switch_start_at timestamp;
  v_requested_return_at timestamp;
  v_recommendations jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to preview a vehicle switch.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Vehicle switches open only after the rental is active.';
  end if;

  if now() < (
    public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
      at time zone 'America/New_York'
  ) - interval '24 hours' then
    raise exception 'Switch requests open 24 hours before the booked return time.';
  end if;

  if p_requested_return_date is null then
    raise exception 'Requested return date is required.';
  end if;

  select *
    into v_vehicle
    from public.vehicles
    where id = v_rental.vehicle_id;

  if not found then
    raise exception 'Vehicle not found.';
  end if;

  v_switch_start_at := public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time);
  v_requested_return_at := public.rentmect_rental_timestamp(
    p_requested_return_date,
    coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time)
  );

  if v_requested_return_at <= v_switch_start_at then
    raise exception 'Continuation return time must be after the current return time.';
  end if;

  with alternatives as (
    select
      vehicles.id,
      vehicles.name,
      vehicles.brand,
      vehicles.model,
      vehicles.vehicle_type,
      vehicles.daily_rate,
      vehicles.security_deposit,
      case
        when nullif(lower(vehicles.model), '') = nullif(lower(v_vehicle.model), '') then 0
        when nullif(lower(vehicles.vehicle_type), '') = nullif(lower(v_vehicle.vehicle_type), '') then 1
        when nullif(lower(vehicles.brand), '') = nullif(lower(v_vehicle.brand), '') then 2
        else 3
      end as similarity_rank
    from public.vehicles
    where vehicles.id <> v_rental.vehicle_id
      and coalesce(lower(vehicles.status), 'available') = 'available'
      and not exists (
        select 1
        from public.rentals r
        where r.vehicle_id = vehicles.id
          and coalesce(lower(r.status), '') <> 'cancelled'
          and r.pickup_date is not null
          and r.return_date is not null
          and public.rentmect_periods_overlap(
            v_switch_start_at,
            v_requested_return_at + interval '3 hours',
            public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
            public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
          )
      )
      and not exists (
        select 1
        from public.vehicle_availability_blocks b
        where b.vehicle_id = vehicles.id
          and coalesce(b.active, true)
          and coalesce(lower(b.block_type), 'unavailable') <> 'available'
          and public.rentmect_periods_overlap(
            v_switch_start_at,
            v_requested_return_at + interval '3 hours',
            public.rentmect_rental_timestamp(b.start_date, b.start_time),
            public.rentmect_rental_timestamp(b.end_date, b.end_time)
          )
      )
    order by similarity_rank, vehicles.daily_rate nulls last, vehicles.name
    limit 8
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', alternatives.id,
        'name', alternatives.name,
        'brand', alternatives.brand,
        'model', alternatives.model,
        'vehicle_type', alternatives.vehicle_type,
        'daily_rate', alternatives.daily_rate,
        'security_deposit', alternatives.security_deposit,
        'continuation_deposit', case
          when coalesce(v_rental.under_25_markup_percentage, 0) > 0
            then public.rentmect_calculate_under25_deposit(alternatives.security_deposit)
          else alternatives.security_deposit
        end,
        'similarity_rank', alternatives.similarity_rank
      )
      order by alternatives.similarity_rank, alternatives.daily_rate nulls last, alternatives.name
    ),
    '[]'::jsonb
  )
    into v_recommendations
    from alternatives;

  return jsonb_build_object(
    'switch_start_date', v_rental.return_date,
    'switch_start_time', coalesce(nullif(trim(v_rental.return_time), ''), '9:00 AM'),
    'requested_return_date', p_requested_return_date,
    'requested_return_time', coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time, '9:00 AM'),
    'current_vehicle', jsonb_build_object(
      'id', v_vehicle.id,
      'name', v_vehicle.name,
      'brand', v_vehicle.brand,
      'model', v_vehicle.model,
      'vehicle_type', v_vehicle.vehicle_type
    ),
    'recommended_vehicles', v_recommendations
  );
end;
$$;

revoke all on function public.preview_customer_vehicle_switch_continuation(uuid, date, text) from public;
grant execute on function public.preview_customer_vehicle_switch_continuation(uuid, date, text) to authenticated;

create or replace function public.request_customer_rental_extension(
  p_rental_id uuid,
  p_requested_return_date date,
  p_requested_return_time text default '9:00 AM',
  p_customer_note text default null
) returns public.rental_extension_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_request public.rental_extension_requests%rowtype;
  v_current_return_at timestamp;
  v_requested_return_at timestamp;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to request an extension.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = p_rental_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Extensions open only after the rental is active.';
  end if;

  if now() < (
    public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
      at time zone 'America/New_York'
  ) - interval '24 hours' then
    raise exception 'Extension requests open 24 hours before the booked return time.';
  end if;

  if p_requested_return_date is null then
    raise exception 'Requested return date is required.';
  end if;

  v_current_return_at := public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time);
  v_requested_return_at := public.rentmect_rental_timestamp(
    p_requested_return_date,
    coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time)
  );

  if v_requested_return_at <= v_current_return_at then
    raise exception 'Extension return time must be after the current return time.';
  end if;

  if exists (
    select 1
    from public.rental_extension_requests
    where rental_id = p_rental_id
      and status in ('pending', 'approved_pending_payment')
  ) then
    raise exception 'This rental already has an open extension request.';
  end if;

  -- Requests do not reserve inventory, but reject an already-known conflict now.
  -- Approval/payment recheck under the vehicle lock before changing the rental.
  if exists (
    select 1
    from public.rentals r
    where r.id <> v_rental.id
      and r.vehicle_id = v_rental.vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and r.pickup_date is not null
      and r.return_date is not null
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        v_requested_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = v_rental.vehicle_id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_current_return_at,
        v_requested_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'This extension conflicts with another booking or calendar block.';
  end if;

  insert into public.rental_extension_requests (
    rental_id,
    user_id,
    original_return_date,
    original_return_time,
    requested_return_date,
    requested_return_time,
    customer_note
  )
  values (
    p_rental_id,
    v_user_id,
    v_rental.return_date,
    coalesce(nullif(trim(v_rental.return_time), ''), '9:00 AM'),
    p_requested_return_date,
    coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time, '9:00 AM'),
    nullif(trim(p_customer_note), '')
  )
  returning * into v_request;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_user_id,
    'rental_extension_requested',
    jsonb_build_object(
      'extension_request_id', v_request.id,
      'requested_return_date', v_request.requested_return_date,
      'requested_return_time', v_request.requested_return_time
    )
  );

  return v_request;
end;
$$;

revoke all on function public.request_customer_rental_extension(uuid, date, text, text) from public;
grant execute on function public.request_customer_rental_extension(uuid, date, text, text) to authenticated;

create or replace function public.request_customer_vehicle_switch_continuation(
  p_rental_id uuid,
  p_replacement_vehicle_id uuid,
  p_requested_return_date date,
  p_requested_return_time text default '9:00 AM',
  p_customer_note text default null
) returns public.rental_extension_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_request public.rental_extension_requests%rowtype;
  v_start_at timestamp;
  v_end_at timestamp;
begin
  if v_user_id is null then raise exception 'You must be signed in to request a switch.'; end if;
  select * into v_rental from public.rentals
    where id = p_rental_id and user_id = v_user_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if p_replacement_vehicle_id is null or p_replacement_vehicle_id = v_rental.vehicle_id then
    raise exception 'Choose a different replacement vehicle.';
  end if;
  if not exists (
    select 1
    from public.vehicles
    where id = p_replacement_vehicle_id
      and coalesce(lower(status), 'available') = 'available'
  ) then
    raise exception 'Replacement vehicle is not available for a switch.';
  end if;
  if lower(coalesce(v_rental.status, '')) not in ('active', 'overdue') then
    raise exception 'Vehicle switches open only after the rental is active.';
  end if;
  if now() < (
    public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
      at time zone 'America/New_York'
  ) - interval '24 hours' then
    raise exception 'Switch requests open 24 hours before the booked return time.';
  end if;
  if p_requested_return_date is null then
    raise exception 'Requested return date is required.';
  end if;
  v_start_at := public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time);
  v_end_at := public.rentmect_rental_timestamp(p_requested_return_date, coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time));
  if v_end_at <= v_start_at then raise exception 'Continuation return time must be after the current return time.'; end if;
  if exists (select 1 from public.rental_extension_requests where rental_id = p_rental_id and status in ('pending', 'approved_pending_payment')) then
    raise exception 'This rental already has an open extension or switch request.';
  end if;
  if exists (
    select 1 from public.rentals r
    where r.vehicle_id = p_replacement_vehicle_id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and r.pickup_date is not null
      and r.return_date is not null
      and public.rentmect_periods_overlap(
        v_start_at, v_end_at + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1 from public.vehicle_availability_blocks b
    where b.vehicle_id = p_replacement_vehicle_id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        v_start_at, v_end_at + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then raise exception 'Replacement vehicle is no longer available for that window.'; end if;

  insert into public.rental_extension_requests (
    rental_id, user_id, request_kind, replacement_vehicle_id,
    original_return_date, original_return_time,
    requested_return_date, requested_return_time, customer_note
  ) values (
    v_rental.id, v_user_id, 'switch_car_continuation', p_replacement_vehicle_id,
    v_rental.return_date, coalesce(nullif(trim(v_rental.return_time), ''), '9:00 AM'),
    p_requested_return_date, coalesce(nullif(trim(p_requested_return_time), ''), v_rental.return_time, '9:00 AM'),
    nullif(trim(p_customer_note), '')
  ) returning * into v_request;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (v_rental.id, v_rental.user_id, v_user_id, 'vehicle_switch_continuation_requested',
    jsonb_build_object('extension_request_id', v_request.id, 'replacement_vehicle_id', p_replacement_vehicle_id));
  return v_request;
end;
$$;

revoke all on function public.request_customer_vehicle_switch_continuation(uuid, uuid, date, text, text) from public;
grant execute on function public.request_customer_vehicle_switch_continuation(uuid, uuid, date, text, text) to authenticated;

create or replace function public.cancel_customer_rental_extension(
  p_extension_request_id uuid
) returns public.rental_extension_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_request public.rental_extension_requests%rowtype;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to cancel an extension request.';
  end if;

  select *
    into v_request
    from public.rental_extension_requests
    where id = p_extension_request_id
      and user_id = v_user_id
    for update;

  if not found then
    raise exception 'Extension request not found.';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Only pending extension requests can be cancelled.';
  end if;

  update public.rental_extension_requests
    set status = 'cancelled',
        updated_at = now()
    where id = v_request.id
    returning * into v_request;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_request.rental_id,
    v_request.user_id,
    v_user_id,
    'rental_extension_cancelled',
    jsonb_build_object('extension_request_id', v_request.id)
  );

  return v_request;
end;
$$;

revoke all on function public.cancel_customer_rental_extension(uuid) from public;
grant execute on function public.cancel_customer_rental_extension(uuid) to authenticated;

create or replace function public.decide_admin_rental_extension(
  p_extension_request_id uuid,
  p_approve boolean,
  p_admin_note text default null
) returns public.rental_extension_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_request public.rental_extension_requests%rowtype;
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_extension_days integer;
  v_extension_rental_amount numeric;
  v_extension_tax_amount numeric;
  v_extension_deposit_amount numeric := 0;
  v_existing_deposit_held numeric := 0;
  v_replacement_deposit_required numeric := 0;
  v_deposit_carried_amount numeric := 0;
  v_deposit_decrease_amount numeric := 0;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required to decide an extension.';
  end if;

  select *
    into v_request
    from public.rental_extension_requests
    where id = p_extension_request_id
    for update;

  if not found then
    raise exception 'Extension request not found.';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Extension request has already been decided.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = v_request.rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if not p_approve then
    update public.rental_extension_requests
      set status = 'rejected',
          admin_note = nullif(trim(p_admin_note), ''),
          decided_by = v_admin_id,
          decided_at = now(),
          updated_at = now()
      where id = v_request.id
      returning * into v_request;

    insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
    values (
      v_rental.id,
      v_rental.user_id,
      v_admin_id,
      'rental_extension_rejected',
      jsonb_build_object('extension_request_id', v_request.id)
    );

    return v_request;
  end if;

  if lower(coalesce(v_rental.status, '')) in ('completed', 'cancelled', 'return_initiated') then
    raise exception 'This rental cannot be extended.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_rental.vehicle_id::text));
  if v_request.request_kind = 'switch_car_continuation' then
    perform pg_advisory_xact_lock(hashtext(v_request.replacement_vehicle_id::text));
  end if;

  select *
    into v_vehicle
    from public.vehicles
    where id = case
      when v_request.request_kind = 'switch_car_continuation' then v_request.replacement_vehicle_id
      else v_rental.vehicle_id
    end
    for update;

  if not found then
    raise exception 'Vehicle not found.';
  end if;

  if v_request.request_kind = 'switch_car_continuation'
     and coalesce(lower(v_vehicle.status), 'available') <> 'available' then
    raise exception 'Replacement vehicle is not available for a switch.';
  end if;

  if public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time)
     <= public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time) then
    raise exception 'Extension return time must be after the current return time.';
  end if;

  if exists (
    select 1
    from public.rentals r
    where r.id <> v_rental.id
      and r.vehicle_id = v_vehicle.id
      and coalesce(lower(r.status), '') <> 'cancelled'
      and r.pickup_date is not null
      and r.return_date is not null
      and public.rentmect_periods_overlap(
        case when v_request.request_kind = 'switch_car_continuation'
          then public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
          else public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time)
        end,
        public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = v_vehicle.id
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time),
        public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'This extension or switch conflicts with another booking or calendar block for the vehicle.';
  end if;

  v_extension_days := greatest(v_request.requested_return_date - coalesce(v_request.original_return_date, v_rental.return_date), 1);
  -- Store the base extension amount. The
  -- rental_extensions_apply_age_markup trigger applies the rental's
  -- snapshotted under-25 percentage exactly once during this approval update.
  v_extension_rental_amount := round(coalesce(v_vehicle.daily_rate, 0) * v_extension_days, 2);
  v_extension_tax_amount := round(v_extension_rental_amount * 0.0635, 2);
  if v_request.request_kind = 'switch_car_continuation' then
    v_existing_deposit_held := greatest(
      coalesce(v_rental.deposit_held_amount, 0),
      case when lower(coalesce(v_rental.deposit_status, '')) = 'held'
        then coalesce(v_rental.security_deposit, 0) else 0 end
    );
    v_replacement_deposit_required := case
      when coalesce(v_rental.under_25_markup_percentage, 0) > 0
        then public.rentmect_calculate_under25_deposit(coalesce(v_vehicle.security_deposit, 0))
      else coalesce(v_vehicle.security_deposit, 0)
    end;
    v_deposit_carried_amount := least(v_existing_deposit_held, v_replacement_deposit_required);
    v_extension_deposit_amount := greatest(v_replacement_deposit_required - v_existing_deposit_held, 0);
    v_deposit_decrease_amount := greatest(v_existing_deposit_held - v_replacement_deposit_required, 0);
  end if;

  update public.rental_extension_requests
    set status = 'approved_pending_payment',
        payment_status = 'pending',
        original_return_date = coalesce(original_return_date, v_rental.return_date),
        original_return_time = coalesce(nullif(trim(original_return_time), ''), v_rental.return_time, '9:00 AM'),
        extension_days = v_extension_days,
        extension_rental_amount = v_extension_rental_amount,
        extension_tax_amount = v_extension_tax_amount,
        extension_deposit_amount = v_extension_deposit_amount,
        existing_deposit_held = v_existing_deposit_held,
        replacement_deposit_required = v_replacement_deposit_required,
        deposit_carried_amount = v_deposit_carried_amount,
        deposit_increase_amount = v_extension_deposit_amount,
        deposit_decrease_amount = v_deposit_decrease_amount,
        extension_total_amount = v_extension_rental_amount + v_extension_tax_amount + v_extension_deposit_amount,
        admin_note = nullif(trim(p_admin_note), ''),
        decided_by = v_admin_id,
        decided_at = now(),
        updated_at = now()
    where id = v_request.id
    returning * into v_request;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
      case when v_request.request_kind = 'switch_car_continuation'
        then 'vehicle_switch_continuation_approved_pending_payment'
        else 'rental_extension_approved_pending_payment'
      end,
    jsonb_build_object(
      'extension_request_id', v_request.id,
      'return_date', v_request.requested_return_date,
      'return_time', v_request.requested_return_time,
      'extension_total_amount', v_request.extension_total_amount
    )
  );

  return v_request;
end;
$$;

revoke all on function public.decide_admin_rental_extension(uuid, boolean, text) from public;
grant execute on function public.decide_admin_rental_extension(uuid, boolean, text) to authenticated;

create or replace function public.record_admin_local_rental_extension_payment(
  p_extension_request_id uuid
) returns public.rental_extension_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_request public.rental_extension_requests%rowtype;
  v_rental public.rentals%rowtype;
  v_replacement public.vehicles%rowtype;
  v_new_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required to record a local extension payment.';
  end if;

  select *
    into v_request
    from public.rental_extension_requests
    where id = p_extension_request_id
    for update;

  if not found then
    raise exception 'Extension request not found.';
  end if;

  if v_request.status <> 'approved_pending_payment'
     or v_request.payment_status <> 'pending' then
    raise exception 'Only approved unpaid extensions can be activated by payment.';
  end if;

  select *
    into v_rental
    from public.rentals
    where id = v_request.rental_id
    for update;

  if not found then
    raise exception 'Rental not found.';
  end if;

  if lower(coalesce(v_rental.status, '')) in ('completed', 'cancelled', 'return_initiated') then
    raise exception 'This rental cannot be extended.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_rental.vehicle_id::text));
  if v_request.request_kind = 'switch_car_continuation' then
    perform pg_advisory_xact_lock(hashtext(v_request.replacement_vehicle_id::text));
    select * into v_replacement from public.vehicles
      where id = v_request.replacement_vehicle_id for update;
    if not found then raise exception 'Replacement vehicle not found.'; end if;
    if coalesce(lower(v_replacement.status), 'available') <> 'available' then
      raise exception 'Replacement vehicle is not available for a switch.';
    end if;
  end if;

  -- Remove this request's calendar hold inside the payment transaction. If any
  -- later validation fails, PostgreSQL rolls this change back automatically.
  perform public.release_extension_calendar_hold(v_request.id);

  if exists (
    select 1
    from public.rentals r
    where r.id <> v_rental.id
      and r.vehicle_id = case when v_request.request_kind = 'switch_car_continuation'
        then v_request.replacement_vehicle_id else v_rental.vehicle_id end
      and coalesce(lower(r.status), '') <> 'cancelled'
      and r.pickup_date is not null
      and r.return_date is not null
      and public.rentmect_periods_overlap(
        case when v_request.request_kind = 'switch_car_continuation'
          then public.rentmect_rental_timestamp(v_request.original_return_date, v_request.original_return_time)
          else public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time)
        end,
        public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time),
        public.rentmect_rental_timestamp(r.return_date, r.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1
    from public.vehicle_availability_blocks b
    where b.vehicle_id = case when v_request.request_kind = 'switch_car_continuation'
      then v_request.replacement_vehicle_id else v_rental.vehicle_id end
      and coalesce(b.active, true)
      and coalesce(lower(b.block_type), 'unavailable') <> 'available'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_request.original_return_date, v_request.original_return_time),
        public.rentmect_rental_timestamp(v_request.requested_return_date, v_request.requested_return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(b.start_date, b.start_time),
        public.rentmect_rental_timestamp(b.end_date, b.end_time)
      )
  ) then
    raise exception 'This extension conflicts with another booking or calendar block for the vehicle.';
  end if;

  if v_request.request_kind = 'switch_car_continuation' then
    insert into public.rentals (
      user_id, vehicle_id, pickup_date, return_date, pickup_time, return_time,
      status, payment_status, deposit_status, paid_at,
      rental_total, tax_amount, security_deposit, deposit_held_amount
    ) values (
      v_rental.user_id, v_replacement.id,
      v_request.original_return_date, v_request.requested_return_date,
      v_request.original_return_time, v_request.requested_return_time,
      'documents_needed', 'paid', 'held', now(),
      coalesce(v_request.extension_rental_amount, 0),
      coalesce(v_request.extension_tax_amount, 0),
      coalesce(v_request.replacement_deposit_required, 0),
      coalesce(v_request.replacement_deposit_required, 0)
    ) returning * into v_new_rental;

    perform public.transfer_rental_deposit_allocations(
      v_rental.id,
      v_new_rental.id,
      coalesce(v_request.replacement_deposit_required, 0),
      'local',
      null
    );
  else
    update public.rentals
      set return_date = v_request.requested_return_date,
          return_time = v_request.requested_return_time,
          rental_total = coalesce(rental_total, 0) + coalesce(v_request.extension_rental_amount, 0),
          tax_amount = coalesce(tax_amount, 0) + coalesce(v_request.extension_tax_amount, 0)
      where id = v_rental.id
      returning * into v_rental;
  end if;

  update public.rental_extension_requests
    set status = 'activated',
        payment_status = 'paid',
        paid_at = now(),
        activated_at = now(),
        replacement_rental_id = coalesce(v_new_rental.id, replacement_rental_id),
        updated_at = now()
    where id = v_request.id
    returning * into v_request;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id,
    v_rental.user_id,
    v_admin_id,
    case when v_request.request_kind = 'switch_car_continuation'
      then 'admin_local_vehicle_switch_payment_recorded'
      else 'admin_local_rental_extension_payment_recorded'
    end,
    jsonb_build_object(
      'extension_request_id', v_request.id,
      'return_date', v_request.requested_return_date,
      'return_time', v_request.requested_return_time,
      'replacement_rental_id', v_new_rental.id,
      'extension_total_amount', v_request.extension_total_amount
    )
  );

  return v_request;
end;
$$;

revoke all on function public.record_admin_local_rental_extension_payment(uuid) from public;
grant execute on function public.record_admin_local_rental_extension_payment(uuid) to authenticated;
