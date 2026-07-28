-- Guarded admin editing for existing rentals.
-- Core schedule changes remain protected by the existing rental integrity
-- trigger. Settled payments are never rewritten: paid increases become a
-- rental charge and paid decreases become an auditable credit due.

create table if not exists public.rental_amendments (
  id uuid primary key default gen_random_uuid(),
  idempotency_key uuid not null unique,
  rental_id uuid not null references public.rentals(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  reason text not null check (length(trim(reason)) >= 10),
  rental_state text not null,
  old_values jsonb not null,
  new_values jsonb not null,
  pricing_delta numeric(10,2) not null default 0,
  deposit_delta numeric(10,2) not null default 0,
  total_delta numeric(10,2) not null default 0,
  settlement_status text not null check (settlement_status in (
    'no_change', 'unpaid_repriced', 'customer_charge_pending',
    'customer_credit_due'
  )),
  adjustment_charge_id uuid references public.rental_charge_items(id) on delete set null,
  credit_amount numeric(10,2) not null default 0 check (credit_amount >= 0),
  requires_customer_resign boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists rental_amendments_rental_created_idx
  on public.rental_amendments (rental_id, created_at desc);

alter table public.rental_amendments enable row level security;
drop policy if exists "Admins read rental amendments" on public.rental_amendments;
create policy "Admins read rental amendments"
on public.rental_amendments for select to authenticated
using (public.is_admin());
grant select on public.rental_amendments to authenticated;

create table if not exists public.rental_vehicle_assignments (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete restrict,
  assigned_from timestamptz not null,
  assigned_until timestamptz,
  source text not null default 'initial' check (source in (
    'initial', 'admin_edit', 'active_swap'
  )),
  amendment_id uuid references public.rental_amendments(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (assigned_until is null or assigned_until >= assigned_from)
);

create index if not exists rental_vehicle_assignments_vehicle_time_idx
  on public.rental_vehicle_assignments (
    vehicle_id, assigned_from, assigned_until
  );
create index if not exists rental_vehicle_assignments_rental_idx
  on public.rental_vehicle_assignments (rental_id, assigned_from);

alter table public.rental_vehicle_assignments enable row level security;
drop policy if exists "Admins read rental vehicle assignments"
on public.rental_vehicle_assignments;
create policy "Admins read rental vehicle assignments"
on public.rental_vehicle_assignments for select to authenticated
using (public.is_admin());
grant select on public.rental_vehicle_assignments to authenticated;

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader,
  html_body, text_body, enabled
) values (
  'rental_amendment_notice',
  'Rental Updated',
  'automated',
  'rental.amended',
  'Your Rent Me CT rental was updated — {{vehicle_name}}',
  'Review your updated vehicle, schedule, and total.',
  '<h1>Your rental was updated.</h1><p>Hi {{customer_first_name}},</p><p>An administrator updated your Rent Me CT reservation.</p><p><strong>Vehicle:</strong> {{vehicle_name}}<br><strong>Pickup:</strong> {{pickup_date}} at {{pickup_time}}<br><strong>Return:</strong> {{return_date}} at {{return_time}}<br><strong>Updated total:</strong> {{updated_total}}</p><p>{{payment_update}}</p><p>{{agreement_update}}</p><p><a href="{{manage_booking_url}}">Review your booking</a></p>',
  'Your Rent Me CT rental was updated. Vehicle: {{vehicle_name}}. Pickup: {{pickup_date}} at {{pickup_time}}. Return: {{return_date}} at {{return_time}}. Updated total: {{updated_total}}. {{payment_update}} {{agreement_update}} Review your booking: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set
  name = excluded.name,
  category = excluded.category,
  trigger_key = excluded.trigger_key,
  subject = excluded.subject,
  preheader = excluded.preheader,
  html_body = excluded.html_body,
  text_body = excluded.text_body,
  enabled = excluded.enabled,
  version = public.email_templates.version + 1,
  updated_at = now();

-- Seed the assignment ledger without changing any rental or availability.
insert into public.rental_vehicle_assignments (
  rental_id, vehicle_id, assigned_from, assigned_until, source
)
select
  rentals.id,
  rentals.vehicle_id,
  public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time)
    at time zone 'America/New_York',
  public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
    at time zone 'America/New_York',
  'initial'
from public.rentals rentals
where rentals.vehicle_id is not null
  and rentals.pickup_date is not null
  and rentals.return_date is not null
  and not exists (
    select 1
    from public.rental_vehicle_assignments assignments
    where assignments.rental_id = rentals.id
  );

create or replace function public.admin_preview_rental_amendment(
  p_rental_id uuid,
  p_vehicle_id uuid,
  p_pickup_date date,
  p_pickup_time text,
  p_return_date date,
  p_return_time text,
  p_daily_rate numeric default null,
  p_security_deposit numeric default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_profile public.profiles%rowtype;
  v_discount public.discount_codes%rowtype;
  v_settings public.under_25_pricing_settings%rowtype;
  v_pickup_at timestamp;
  v_return_at timestamp;
  v_days integer;
  v_daily_rate numeric;
  v_base_rental numeric;
  v_pre_discount_rental numeric;
  v_discount_amount numeric := 0;
  v_rental_total numeric;
  v_tax_amount numeric;
  v_base_deposit numeric;
  v_security_deposit numeric;
  v_under_25 boolean := false;
  v_current_pricing_total numeric;
  v_new_pricing_total numeric;
  v_current_total numeric;
  v_new_total numeric;
  v_pricing_delta numeric;
  v_deposit_delta numeric;
  v_total_delta numeric;
  v_core_changed boolean;
  v_financial_changed boolean;
  v_requires_resign boolean;
  v_settlement_status text;
begin
  if auth.role() <> 'service_role'
     and (auth.uid() is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'cancelled' then
    raise exception 'Cancelled rentals must be reactivated through a separate reviewed workflow.';
  end if;

  if p_vehicle_id is null then raise exception 'Choose a vehicle.'; end if;
  if p_pickup_date is null or p_return_date is null then
    raise exception 'Pickup and return dates are required.';
  end if;
  v_pickup_at := public.rentmect_rental_timestamp(
    p_pickup_date, coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM')
  );
  v_return_at := public.rentmect_rental_timestamp(
    p_return_date, coalesce(nullif(trim(p_return_time), ''), '9:00 AM')
  );
  if v_return_at <= v_pickup_at then
    raise exception 'Return time must be after pickup time.';
  end if;
  v_days := p_return_date - p_pickup_date;
  if v_days < 1 then raise exception 'A rental must span at least one day.'; end if;

  select * into v_vehicle
  from public.vehicles
  where id = p_vehicle_id;
  if not found then raise exception 'Vehicle not found.'; end if;
  if p_vehicle_id = '00000000-0000-4000-8000-000000000015'::uuid then
    raise exception 'The booking-flow test vehicle cannot be assigned to a real rental.';
  end if;
  if not coalesce(v_vehicle.is_active, true) then
    raise exception 'The selected vehicle is inactive.';
  end if;
  if coalesce(v_vehicle.maintenance_lock_active, false)
     and p_vehicle_id is distinct from v_rental.vehicle_id then
    raise exception 'The selected vehicle is maintenance-locked.';
  end if;
  if lower(coalesce(v_vehicle.status, 'available')) in (
    'maintenance', 'unavailable', 'inactive', 'retired'
  ) and p_vehicle_id is distinct from v_rental.vehicle_id then
    raise exception 'The selected vehicle is not operationally available.';
  end if;

  v_core_changed :=
    p_vehicle_id is distinct from v_rental.vehicle_id
    or p_pickup_date is distinct from v_rental.pickup_date
    or p_return_date is distinct from v_rental.return_date
    or coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM')
      is distinct from coalesce(v_rental.pickup_time, '9:00 AM')
    or coalesce(nullif(trim(p_return_time), ''), '9:00 AM')
      is distinct from coalesce(v_rental.return_time, '9:00 AM');

  if v_core_changed
     and lower(coalesce(v_rental.status, '')) in (
       'active', 'rented', 'overdue', 'return_initiated'
     )
     and v_return_at <= (now() at time zone 'America/New_York') then
    raise exception 'An active rental must have a return time in the future.';
  end if;

  if v_core_changed and exists (
    select 1
    from public.rentals rentals
    where rentals.id <> v_rental.id
      and rentals.vehicle_id = p_vehicle_id
      and lower(coalesce(rentals.status, '')) <> 'cancelled'
      and rentals.pickup_date is not null
      and rentals.return_date is not null
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(rentals.pickup_date, rentals.pickup_time),
        public.rentmect_rental_timestamp(rentals.return_date, rentals.return_time)
          + interval '3 hours'
      )
  ) then
    raise exception 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.';
  end if;

  if v_core_changed and exists (
    select 1
    from public.vehicle_availability_blocks blocks
    where blocks.vehicle_id = p_vehicle_id
      and coalesce(blocks.active, true)
      and lower(coalesce(blocks.block_type, 'unavailable')) <> 'available'
      and public.rentmect_periods_overlap(
        v_pickup_at,
        v_return_at + interval '3 hours',
        public.rentmect_rental_timestamp(blocks.start_date, blocks.start_time),
        public.rentmect_rental_timestamp(blocks.end_date, blocks.end_time)
      )
  ) then
    raise exception 'Vehicle schedule conflict: the admin calendar blocks this time.';
  end if;

  select * into v_profile
  from public.profiles
  where id = v_rental.user_id;
  if not found or v_profile.date_of_birth is null then
    raise exception 'The customer must have a valid date of birth before repricing.';
  end if;
  v_under_25 :=
    age((now() at time zone 'America/New_York')::date, v_profile.date_of_birth)
      < interval '25 years';
  select * into v_settings
  from public.under_25_pricing_settings
  where id = true;

  v_daily_rate := round(coalesce(p_daily_rate, v_vehicle.daily_rate, 0), 2);
  if v_daily_rate < 0 or v_daily_rate > 100000 then
    raise exception 'Daily rate must be between $0 and $100,000.';
  end if;
  v_base_rental := round(v_daily_rate * v_days, 2);
  v_pre_discount_rental := case
    when v_under_25
      then public.rentmect_calculate_under25_rental(v_base_rental)
    else v_base_rental
  end;

  if v_rental.discount_code_id is not null then
    select * into v_discount
    from public.discount_codes
    where id = v_rental.discount_code_id;
    if found then
      v_discount_amount := case
        when v_discount.discount_type = 'percentage'
          then round(v_pre_discount_rental * v_discount.amount / 100, 2)
        else least(round(v_discount.amount, 2), v_pre_discount_rental)
      end;
    end if;
  end if;
  v_rental_total := round(v_pre_discount_rental - v_discount_amount, 2);
  v_tax_amount := round((
    v_rental_total + coalesce(v_rental.taxable_service_fee_total, 0)
  ) * 0.0635, 2);

  v_base_deposit := round(coalesce(v_vehicle.security_deposit, 0), 2);
  v_security_deposit := case
    when p_security_deposit is not null then round(p_security_deposit, 2)
    when v_under_25 then public.rentmect_calculate_under25_deposit(v_base_deposit)
    else v_base_deposit
  end;
  if v_security_deposit < 0 or v_security_deposit > 100000 then
    raise exception 'Security deposit must be between $0 and $100,000.';
  end if;
  if lower(coalesce(v_rental.payment_status, 'pending')) = 'paid'
     and abs(v_security_deposit - coalesce(v_rental.security_deposit, 0)) > 0.005 then
    raise exception 'A paid rental deposit cannot be rewritten. Keep the held deposit unchanged and use the protected deposit adjustment workflow.';
  end if;

  v_current_pricing_total := round(
    coalesce(v_rental.rental_total, 0)
    + coalesce(v_rental.service_fee_total, 0)
    + coalesce(v_rental.tax_amount, 0), 2
  );
  v_new_pricing_total := round(
    v_rental_total
    + coalesce(v_rental.service_fee_total, 0)
    + v_tax_amount, 2
  );
  v_current_total := round(
    v_current_pricing_total + coalesce(v_rental.security_deposit, 0), 2
  );
  v_new_total := round(v_new_pricing_total + v_security_deposit, 2);
  v_pricing_delta := round(v_new_pricing_total - v_current_pricing_total, 2);
  v_deposit_delta := round(v_security_deposit - coalesce(v_rental.security_deposit, 0), 2);
  v_total_delta := round(v_new_total - v_current_total, 2);
  v_financial_changed :=
    abs(v_pricing_delta) > 0.005 or abs(v_deposit_delta) > 0.005;
  v_requires_resign := coalesce(v_rental.agreement_signed, false)
    and lower(coalesce(v_rental.status, '')) <> 'completed'
    and (v_core_changed or v_financial_changed);

  v_settlement_status := case
    when lower(coalesce(v_rental.payment_status, 'pending')) <> 'paid'
      then 'unpaid_repriced'
    when v_total_delta > 0.005 then 'customer_charge_pending'
    when v_total_delta < -0.005 then 'customer_credit_due'
    else 'no_change'
  end;

  return jsonb_build_object(
    'rental_id', v_rental.id,
    'rental_state', v_rental.status,
    'payment_status', v_rental.payment_status,
    'vehicle_changed', p_vehicle_id is distinct from v_rental.vehicle_id,
    'schedule_changed', v_core_changed,
    'requires_customer_resign', v_requires_resign,
    'settlement_status', v_settlement_status,
    'old', jsonb_build_object(
      'vehicle_id', v_rental.vehicle_id,
      'vehicle_name', (
        select name from public.vehicles where id = v_rental.vehicle_id
      ),
      'pickup_date', v_rental.pickup_date,
      'pickup_time', v_rental.pickup_time,
      'return_date', v_rental.return_date,
      'return_time', v_rental.return_time,
      'rental_total', coalesce(v_rental.rental_total, 0),
      'service_fee_total', coalesce(v_rental.service_fee_total, 0),
      'tax_amount', coalesce(v_rental.tax_amount, 0),
      'security_deposit', coalesce(v_rental.security_deposit, 0),
      'total', v_current_total
    ),
    'new', jsonb_build_object(
      'vehicle_id', p_vehicle_id,
      'vehicle_name', v_vehicle.name,
      'vehicle_published', coalesce(v_vehicle.published, true),
      'pickup_date', p_pickup_date,
      'pickup_time', coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
      'return_date', p_return_date,
      'return_time', coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
      'days', v_days,
      'daily_rate', v_daily_rate,
      'base_rental_total', v_base_rental,
      'pre_discount_rental_total', v_pre_discount_rental,
      'discount_code', v_rental.discount_code,
      'discount_amount', v_discount_amount,
      'rental_total', v_rental_total,
      'service_fee_total', coalesce(v_rental.service_fee_total, 0),
      'tax_amount', v_tax_amount,
      'base_security_deposit', v_base_deposit,
      'security_deposit', v_security_deposit,
      'total', v_new_total
    ),
    'pricing_delta', v_pricing_delta,
    'deposit_delta', v_deposit_delta,
    'total_delta', v_total_delta
  );
end;
$$;

revoke all on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) from public;
grant execute on function public.admin_preview_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric
) to authenticated, service_role;

create or replace function public.admin_apply_rental_amendment(
  p_rental_id uuid,
  p_vehicle_id uuid,
  p_pickup_date date,
  p_pickup_time text,
  p_return_date date,
  p_return_time text,
  p_daily_rate numeric,
  p_security_deposit numeric,
  p_reason text,
  p_admin_notes text,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_updated public.rentals%rowtype;
  v_existing public.rental_amendments%rowtype;
  v_amendment public.rental_amendments%rowtype;
  v_preview jsonb;
  v_charge public.rental_charge_items%rowtype;
  v_old_pickup_at timestamptz;
  v_new_pickup_at timestamptz;
  v_new_return_at timestamptz;
  v_effective_at timestamptz;
  v_vehicle_changed boolean;
  v_schedule_changed boolean;
  v_requires_resign boolean;
  v_settlement_status text;
  v_total_delta numeric;
begin
  if auth.role() <> 'service_role'
     and (v_actor_id is null or not public.is_admin()) then
    raise exception 'Admin access is required.';
  end if;
  if p_idempotency_key is null then raise exception 'Idempotency key is required.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then
    raise exception 'Enter a specific reason of at least 10 characters.';
  end if;

  select * into v_existing
  from public.rental_amendments
  where idempotency_key = p_idempotency_key;
  if found then
    select * into v_updated from public.rentals where id = v_existing.rental_id;
    return jsonb_build_object(
      'amendment', to_jsonb(v_existing),
      'rental', to_jsonb(v_updated),
      'idempotent_replay', true
    );
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) = 'completed'
     and length(trim(p_reason)) < 20 then
    raise exception 'Closed-rental corrections require a reason of at least 20 characters.';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));
  v_preview := public.admin_preview_rental_amendment(
    p_rental_id, p_vehicle_id, p_pickup_date, p_pickup_time,
    p_return_date, p_return_time, p_daily_rate, p_security_deposit
  );
  v_vehicle_changed := coalesce((v_preview ->> 'vehicle_changed')::boolean, false);
  v_schedule_changed := coalesce((v_preview ->> 'schedule_changed')::boolean, false);
  v_requires_resign := coalesce((v_preview ->> 'requires_customer_resign')::boolean, false);
  v_settlement_status := v_preview ->> 'settlement_status';
  v_total_delta := round(coalesce((v_preview ->> 'total_delta')::numeric, 0), 2);

  if not v_schedule_changed
     and abs(coalesce((v_preview ->> 'pricing_delta')::numeric, 0)) <= 0.005
     and abs(coalesce((v_preview ->> 'deposit_delta')::numeric, 0)) <= 0.005
     and nullif(trim(coalesce(p_admin_notes, '')), '') is not distinct from
       nullif(trim(coalesce(v_rental.admin_notes, '')), '') then
    raise exception 'No rental changes were entered.';
  end if;

  insert into public.rental_amendments (
    idempotency_key, rental_id, actor_id, reason, rental_state,
    old_values, new_values, pricing_delta, deposit_delta, total_delta,
    settlement_status, credit_amount, requires_customer_resign
  ) values (
    p_idempotency_key, v_rental.id, v_actor_id, trim(p_reason),
    coalesce(v_rental.status, 'unknown'),
    (v_preview -> 'old') || jsonb_build_object(
      'admin_notes', v_rental.admin_notes
    ),
    (v_preview -> 'new') || jsonb_build_object(
      'admin_notes', nullif(trim(p_admin_notes), '')
    ),
    round(coalesce((v_preview ->> 'pricing_delta')::numeric, 0), 2),
    round(coalesce((v_preview ->> 'deposit_delta')::numeric, 0), 2),
    v_total_delta, v_settlement_status,
    case when v_settlement_status = 'customer_credit_due'
      then abs(v_total_delta) else 0 end,
    v_requires_resign
  ) returning * into v_amendment;

  v_old_pickup_at := public.rentmect_rental_timestamp(
    v_rental.pickup_date, v_rental.pickup_time
  ) at time zone 'America/New_York';
  v_new_pickup_at := public.rentmect_rental_timestamp(
    p_pickup_date, coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM')
  ) at time zone 'America/New_York';
  v_new_return_at := public.rentmect_rental_timestamp(
    p_return_date, coalesce(nullif(trim(p_return_time), ''), '9:00 AM')
  ) at time zone 'America/New_York';

  insert into public.rental_vehicle_assignments (
    rental_id, vehicle_id, assigned_from, assigned_until, source, created_by
  )
  select
    v_rental.id, v_rental.vehicle_id, v_old_pickup_at,
    public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)
      at time zone 'America/New_York',
    'initial', v_actor_id
  where v_rental.vehicle_id is not null
    and not exists (
      select 1 from public.rental_vehicle_assignments
      where rental_id = v_rental.id
    );

  if v_vehicle_changed then
    v_effective_at := case
      when lower(coalesce(v_rental.status, '')) in (
        'active', 'rented', 'overdue', 'return_initiated'
      ) and now() > v_old_pickup_at
        then now()
      else v_new_pickup_at
    end;

    update public.rental_vehicle_assignments
    set assigned_until = greatest(assigned_from, v_effective_at)
    where id = (
      select assignments.id
      from public.rental_vehicle_assignments assignments
      where assignments.rental_id = v_rental.id
      order by assignments.assigned_from desc, assignments.created_at desc
      limit 1
    );

    insert into public.rental_vehicle_assignments (
      rental_id, vehicle_id, assigned_from, assigned_until, source,
      amendment_id, created_by
    ) values (
      v_rental.id, p_vehicle_id, v_effective_at, v_new_return_at,
      case when v_effective_at > v_new_pickup_at then 'active_swap'
        else 'admin_edit' end,
      v_amendment.id, v_actor_id
    );
  elsif v_schedule_changed then
    if lower(coalesce(v_rental.status, '')) in (
      'active', 'rented', 'overdue', 'return_initiated'
    ) and now() > v_old_pickup_at then
      update public.rental_vehicle_assignments
      set assigned_until = v_new_return_at
      where id = (
        select assignments.id
        from public.rental_vehicle_assignments assignments
        where assignments.rental_id = v_rental.id
        order by assignments.assigned_from desc, assignments.created_at desc
        limit 1
      );
    else
      update public.rental_vehicle_assignments
      set assigned_from = v_new_pickup_at,
          assigned_until = v_new_return_at
      where id = (
        select assignments.id
        from public.rental_vehicle_assignments assignments
        where assignments.rental_id = v_rental.id
        order by assignments.assigned_from desc, assignments.created_at desc
        limit 1
      );
    end if;
  end if;

  if v_schedule_changed then
    update public.rentals
    set vehicle_id = p_vehicle_id,
        pickup_date = p_pickup_date,
        pickup_time = coalesce(nullif(trim(p_pickup_time), ''), '9:00 AM'),
        return_date = p_return_date,
        return_time = coalesce(nullif(trim(p_return_time), ''), '9:00 AM'),
        admin_notes = nullif(trim(p_admin_notes), ''),
        agreement_signed = case when v_requires_resign then false else agreement_signed end,
        agreement_version = case when v_requires_resign then null else agreement_version end,
        agreement_snapshot = case when v_requires_resign then null else agreement_snapshot end,
        agreement_hash = case when v_requires_resign then null else agreement_hash end,
        agreement_signed_at = case when v_requires_resign then null else agreement_signed_at end,
        agreement_signature_name = case when v_requires_resign then null else agreement_signature_name end,
        agreement_ip = case when v_requires_resign then null else agreement_ip end,
        agreement_user_agent = case when v_requires_resign then null else agreement_user_agent end,
        status = case
          when v_requires_resign
            and lower(coalesce(status, '')) in ('approved', 'ready_for_pickup')
            then 'document_review'
          else status
        end,
        updated_at = now()
    where id = v_rental.id;
  else
    update public.rentals
    set admin_notes = nullif(trim(p_admin_notes), ''),
        agreement_signed = case when v_requires_resign then false else agreement_signed end,
        agreement_version = case when v_requires_resign then null else agreement_version end,
        agreement_snapshot = case when v_requires_resign then null else agreement_snapshot end,
        agreement_hash = case when v_requires_resign then null else agreement_hash end,
        agreement_signed_at = case when v_requires_resign then null else agreement_signed_at end,
        agreement_signature_name = case when v_requires_resign then null else agreement_signature_name end,
        agreement_ip = case when v_requires_resign then null else agreement_ip end,
        agreement_user_agent = case when v_requires_resign then null else agreement_user_agent end,
        updated_at = now()
    where id = v_rental.id;
  end if;

  -- Monetary fields are written separately so the normal schedule/pricing
  -- triggers can validate the core update without overriding the reviewed
  -- amendment quote.
  update public.rentals
  set base_rental_total = (v_preview #>> '{new,base_rental_total}')::numeric,
      pre_discount_rental_total = (v_preview #>> '{new,pre_discount_rental_total}')::numeric,
      under_25_markup_amount = round(
        (v_preview #>> '{new,pre_discount_rental_total}')::numeric
          - (v_preview #>> '{new,base_rental_total}')::numeric, 2
      ),
      rental_total = (v_preview #>> '{new,rental_total}')::numeric,
      discount_amount = (v_preview #>> '{new,discount_amount}')::numeric,
      tax_amount = (v_preview #>> '{new,tax_amount}')::numeric,
      base_security_deposit = (v_preview #>> '{new,base_security_deposit}')::numeric,
      security_deposit = (v_preview #>> '{new,security_deposit}')::numeric,
      payment_amount_cents = case
        when lower(coalesce(payment_status, 'pending')) <> 'paid'
          then round((v_preview #>> '{new,total}')::numeric * 100)::integer
        else payment_amount_cents
      end,
      updated_at = now()
  where id = v_rental.id
  returning * into v_updated;

  if v_settlement_status = 'customer_charge_pending' then
    insert into public.rental_charge_items (
      rental_id, user_id, name, charge_type, description,
      amount, taxable, tax_amount, total_amount,
      included_in_initial_payment, status, created_by,
      source_type, source_reference
    ) values (
      v_updated.id, v_updated.user_id, 'Rental amendment balance',
      'rental_amendment',
      'Amount due after an administrator changed the rental terms.',
      v_total_delta, false, 0, v_total_delta,
      false, 'pending', v_actor_id,
      'rental_amendment', v_amendment.id::text
    ) returning * into v_charge;

    update public.rental_amendments
    set adjustment_charge_id = v_charge.id
    where id = v_amendment.id
    returning * into v_amendment;
  end if;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_updated.id, v_updated.user_id, v_actor_id,
    'admin_rental_amended',
    jsonb_build_object(
      'amendment_id', v_amendment.id,
      'reason', v_amendment.reason,
      'old', v_amendment.old_values,
      'new', v_amendment.new_values,
      'settlement_status', v_amendment.settlement_status,
      'total_delta', v_amendment.total_delta,
      'requires_customer_resign', v_amendment.requires_customer_resign
    )
  );

  if v_schedule_changed or abs(v_total_delta) > 0.005 or v_requires_resign then
    insert into public.email_outbox (
      event_key, email_type, template_id, rental_id, user_id,
      recipient_email, recipient_name, payload
    )
    select
      'rental_amendment:' || v_amendment.id::text,
      'rental_amendment_notice',
      templates.id,
      v_updated.id,
      v_updated.user_id,
      lower(trim(profiles.email)),
      profiles.full_name,
      jsonb_build_object(
        'customer_name', coalesce(profiles.full_name, 'Customer'),
        'customer_first_name',
          split_part(coalesce(profiles.full_name, 'Customer'), ' ', 1),
        'vehicle_name', coalesce(vehicles.name, 'Your rental vehicle'),
        'pickup_date',
          coalesce(to_char(v_updated.pickup_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
        'pickup_time', coalesce(v_updated.pickup_time, 'To be confirmed'),
        'return_date',
          coalesce(to_char(v_updated.return_date, 'Mon FMDD, YYYY'), 'To be confirmed'),
        'return_time', coalesce(v_updated.return_time, 'To be confirmed'),
        'updated_total',
          to_char((v_preview #>> '{new,total}')::numeric, 'FM$999,999,990.00'),
        'payment_update', case v_settlement_status
          when 'customer_charge_pending' then
            'An additional balance of '
              || to_char(v_total_delta, 'FM$999,999,990.00')
              || ' is ready to review and pay in your portal.'
          when 'customer_credit_due' then
            'A credit of '
              || to_char(abs(v_total_delta), 'FM$999,999,990.00')
              || ' is recorded for administrator review.'
          when 'unpaid_repriced' then
            'Your unpaid checkout total has been updated.'
          else 'Your payment total did not change.'
        end,
        'agreement_update', case when v_requires_resign
          then 'Please review and sign the updated rental agreement before pickup.'
          else 'Your signed agreement status did not change.'
        end,
        'manage_booking_url', 'https://login.rentmect.com'
      )
    from public.profiles profiles
    join public.email_templates templates
      on templates.template_key = 'rental_amendment_notice'
     and templates.enabled
    left join public.vehicles vehicles on vehicles.id = v_updated.vehicle_id
    where profiles.id = v_updated.user_id
      and nullif(trim(coalesce(profiles.email, '')), '') is not null
    on conflict (event_key) do nothing;
  end if;

  return jsonb_build_object(
    'amendment', to_jsonb(v_amendment),
    'rental', to_jsonb(v_updated),
    'charge', case when v_charge.id is null then null else to_jsonb(v_charge) end,
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.admin_apply_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric,
  text, text, uuid
) from public;
grant execute on function public.admin_apply_rental_amendment(
  uuid, uuid, date, text, date, text, numeric, numeric,
  text, text, uuid
) to authenticated, service_role;

comment on table public.rental_amendments is
  'Immutable before/after record of guarded administrator rental edits and their financial settlement.';
comment on table public.rental_vehicle_assignments is
  'Time-bounded vehicle history used to preserve toll and operational attribution across rental swaps.';
