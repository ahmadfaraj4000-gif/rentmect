begin;

-- Opt in on the first swap/extension. Legacy invoices are snapshotted exactly;
-- historical discounts and already-issued charges are never recomputed.
create table public.rental_pricing_periods (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  daily_rate numeric not null check (daily_rate >= 0 and daily_rate <= 100000),
  billing_units numeric not null check (billing_units > 0),
  markup_percentage numeric not null default 0,
  rental_amount numeric(12,2) not null,
  tax_amount numeric(12,2) not null,
  source text not null check (source in ('booking_snapshot','swap','extension')),
  extension_request_id uuid unique references public.rental_extension_requests(id),
  created_at timestamptz not null default now()
);
create index on public.rental_pricing_periods(rental_id, starts_at);
create table public.rental_vehicle_swaps (
  id uuid primary key,
  rental_id uuid not null references public.rentals(id),
  vehicle_id uuid not null references public.vehicles(id),
  effective_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  actor_id uuid references auth.users(id),
  swap_kind text not null check (swap_kind in ('customer_request','emergency','maintenance')),
  reason text not null check (length(trim(reason)) >= 10),
  request jsonb not null,
  financial_effect jsonb not null
);
alter table public.rental_vehicle_assignments add column swap_id uuid references public.rental_vehicle_swaps(id);
alter table public.rental_pricing_periods enable row level security;
alter table public.rental_vehicle_swaps enable row level security;
create policy pricing_period_read on public.rental_pricing_periods for select to authenticated
using (public.is_admin() or exists(select 1 from public.rentals r where r.id=rental_id and r.user_id=auth.uid()));
create policy vehicle_swap_read on public.rental_vehicle_swaps for select to authenticated
using (public.is_admin() or exists(select 1 from public.rentals r where r.id=rental_id and r.user_id=auth.uid()));
grant select on public.rental_pricing_periods, public.rental_vehicle_swaps to authenticated;

alter table public.rental_extension_requests
  add column agreed_daily_rate numeric,
  add column agreed_markup_percentage numeric,
  add column pricing_reason text;

-- Read-only legacy bridge: reconstruct already activated extension agreements,
-- preserving their cents and discounts. Merely previewing never edits a rental.
create function public.rentmect_pricing_snapshot(p_rental_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r public.rentals%rowtype; e record; result jsonb; units numeric; rate numeric;
  baseline_end timestamptz; baseline_date date; baseline_time text; amount numeric; tax numeric;
begin
  select jsonb_agg(p order by starts_at) into result from public.rental_pricing_periods p where rental_id=p_rental_id;
  if result is not null then return result; end if;
  select * into strict r from public.rentals where id=p_rental_id;
  select original_return_date,original_return_time into baseline_date,baseline_time from public.rental_extension_requests
    where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated'
    order by public.rentmect_rental_timestamp(original_return_date,original_return_time) limit 1;
  baseline_date:=coalesce(baseline_date,r.return_date); baseline_time:=coalesce(baseline_time,r.return_time);
  baseline_end:=public.rentmect_rental_timestamp(baseline_date,baseline_time) at time zone 'America/New_York';
  units:=public.rentmect_billable_days(r.pickup_date,r.pickup_time,baseline_date,baseline_time);
  select coalesce(r.rental_total,0)-coalesce(sum(extension_rental_amount),0),coalesce(r.tax_amount,0)-coalesce(sum(extension_tax_amount),0)
    into amount,tax from public.rental_extension_requests where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated';
  if amount<0 or tax<0 then raise exception 'Legacy extension charges exceed the invoice. Reconcile this rental before swapping.'; end if;
  rate:=coalesce(r.base_rental_total,(amount+coalesce(r.discount_amount,0)+coalesce(r.manual_discount_amount,0))/(1+coalesce(r.under_25_markup_percentage,0)/100))/units;
  result:=jsonb_build_array(jsonb_build_object('rental_id',r.id,
    'starts_at',public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
    'ends_at',baseline_end,'daily_rate',rate,'billing_units',units,'markup_percentage',coalesce(r.under_25_markup_percentage,0),
    'rental_amount',amount,'tax_amount',tax,'source','booking_snapshot'));
  for e in select * from public.rental_extension_requests where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated'
    order by public.rentmect_rental_timestamp(original_return_date,original_return_time) loop
    units:=coalesce(e.extension_days,public.rentmect_billable_days(e.original_return_date,e.original_return_time,e.requested_return_date,e.requested_return_time));
    result:=result||jsonb_build_array(jsonb_build_object('rental_id',r.id,
      'starts_at',public.rentmect_rental_timestamp(e.original_return_date,e.original_return_time) at time zone 'America/New_York',
      'ends_at',public.rentmect_rental_timestamp(e.requested_return_date,e.requested_return_time) at time zone 'America/New_York',
      'daily_rate',coalesce(e.agreed_daily_rate,e.extension_rental_amount/units/(1+coalesce(r.under_25_markup_percentage,0)/100)),
      'billing_units',units,'markup_percentage',coalesce(e.agreed_markup_percentage,r.under_25_markup_percentage,0),
      'rental_amount',e.extension_rental_amount,'tax_amount',e.extension_tax_amount,'source','extension','extension_request_id',e.id));
  end loop;
  return result;
end; $$;

create function public.rentmect_initialize_pricing_periods(p_rental_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  if exists(select 1 from public.rental_pricing_periods where rental_id=p_rental_id) then return; end if;
  insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,
    markup_percentage,rental_amount,tax_amount,source,extension_request_id)
  select rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source,extension_request_id
    from jsonb_populate_recordset(null::public.rental_pricing_periods,public.rentmect_pricing_snapshot(p_rental_id));
end; $$;

-- A period carries a share of already established billable units. Splitting it
-- never calls ceil() twice, and amounts on both sides sum to the original cents.
create function public.rentmect_pricing_fraction(p_start timestamptz,p_end timestamptz,p_at timestamptz)
returns numeric language sql immutable as $$
  select greatest(0,least(1,extract(epoch from (p_at-p_start))/nullif(extract(epoch from (p_end-p_start)),0)));
$$;

create function public.rentmect_validate_periods()
returns trigger language plpgsql security definer set search_path=public as $$
declare rid uuid:=coalesce(new.rental_id,old.rental_id); r public.rentals%rowtype; first_at timestamptz; last_at timestamptz;
begin
  select * into r from public.rentals where id=rid;
  if not exists(select 1 from public.rental_pricing_periods where rental_id=rid) then return null; end if;
  if exists(select 1 from (
    select starts_at,lag(ends_at) over(order by starts_at,id) as previous_end
    from public.rental_pricing_periods where rental_id=rid
  ) p where previous_end is not null and previous_end<>starts_at) then
    raise exception 'Pricing periods must have no gaps or overlaps.';
  end if;
  select min(starts_at),max(ends_at) into first_at,last_at from public.rental_pricing_periods where rental_id=rid;
  if first_at is distinct from (public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')
    or last_at is distinct from (public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') then
    raise exception 'Pricing periods must cover the original rental through its booked return.';
  end if;
  if exists(select 1 from (
    select assigned_from,assigned_until,lag(assigned_until) over(order by assigned_from,id) as previous_end
    from public.rental_vehicle_assignments where rental_id=rid
  ) a where assigned_until is null or assigned_until<=assigned_from
    or (previous_end is not null and previous_end<>assigned_from)) then
    raise exception 'Vehicle assignments must have no gaps or overlaps.';
  end if;
  select min(assigned_from),max(assigned_until) into first_at,last_at from public.rental_vehicle_assignments where rental_id=rid;
  if first_at is distinct from (public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')
    or last_at is distinct from coalesce(r.inspection_completed_at,public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') then
    raise exception 'Vehicle assignments must cover the original rental through its return.';
  end if;
  return null;
end; $$;
create constraint trigger pricing_period_continuity after insert or update or delete on public.rental_pricing_periods
  deferrable initially deferred for each row execute function public.rentmect_validate_periods();
create constraint trigger assignment_period_continuity after insert or update or delete on public.rental_vehicle_assignments
  deferrable initially deferred for each row execute function public.rentmect_validate_periods();

create function public.rentmect_assert_swap_available(p_rental_id uuid,p_vehicle_id uuid,p_from timestamptz,p_until timestamptz)
returns void language plpgsql security definer set search_path=public as $$
begin
  perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));
  if exists(select 1 from public.rental_vehicle_assignments a join public.rentals r on r.id=a.rental_id
    where a.rental_id<>p_rental_id and a.vehicle_id=p_vehicle_id and r.status<>'cancelled'
    and p_from<coalesce(a.assigned_until,'infinity'::timestamptz)+interval '3 hours'
    and p_until+interval '3 hours'>a.assigned_from)
  or exists(select 1 from public.rentals r where r.id<>p_rental_id and r.vehicle_id=p_vehicle_id
    and r.status not in ('completed','cancelled') and public.rentmect_requires_physical_return_lock(r.status,r.return_date,r.return_time))
  or exists(select 1 from public.vehicle_availability_blocks b where b.vehicle_id=p_vehicle_id and coalesce(b.active,true)
    and lower(coalesce(b.block_type,'unavailable'))<>'available'
    and p_from<(public.rentmect_rental_timestamp(b.end_date,b.end_time) at time zone 'America/New_York')
    and p_until+interval '3 hours'>(public.rentmect_rental_timestamp(b.start_date,b.start_time) at time zone 'America/New_York'))
  or exists(select 1 from public.pending_bookings b where b.vehicle_id=p_vehicle_id and b.status='pending' and b.expires_at>now()
    and p_from<(public.rentmect_rental_timestamp(b.return_date,b.return_time) at time zone 'America/New_York')+interval '3 hours'
    and p_until+interval '3 hours'>(public.rentmect_rental_timestamp(b.pickup_date,b.pickup_time) at time zone 'America/New_York')) then
    raise exception 'Replacement vehicle conflicts with an assignment, return, calendar block, or checkout hold.';
  end if;
end; $$;

create function public.admin_preview_vehicle_swap(p_rental_id uuid,p_vehicle_id uuid,p_effective_at timestamptz,
  p_swap_kind text,p_reason text,p_daily_rate numeric default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; a public.rental_vehicle_assignments%rowtype; p record;
  until_at timestamptz; delta numeric:=0; tax_delta numeric:=0; units numeric; part numeric; change numeric;
  periods jsonb:='[]'; invoice numeric; paid numeric; additional numeric; fingerprint text;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then
    raise exception 'Rental editing permission is required.'; end if;
  if p_swap_kind is null or p_swap_kind not in ('customer_request','emergency','maintenance')
    or length(trim(coalesce(p_reason,'')))<10 or p_effective_at is null then
    raise exception 'A swap type, effective time, and specific reason are required.'; end if;
  select * into strict r from public.rentals where id=p_rental_id for update;
  if r.status not in ('active','rented','overdue','return_initiated','completed') then raise exception 'Only a started rental can be swapped.'; end if;
  until_at:=public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York';
  if p_effective_at<=(public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')
    or p_effective_at>=until_at or p_effective_at>now() then raise exception 'Effective time must be inside the rental and cannot be in the future.'; end if;
  select * into a from public.rental_vehicle_assignments where rental_id=r.id order by assigned_from desc limit 1;
  if a.id is null or p_effective_at<=a.assigned_from or p_effective_at>=a.assigned_until or a.vehicle_id=p_vehicle_id then
    raise exception 'Choose a different vehicle and a time after the latest assignment began.'; end if;
  if not exists(select 1 from public.vehicles where id=p_vehicle_id and coalesce(is_active,true)
    and not coalesce(maintenance_lock_active,false) and lower(coalesce(status,'available')) not in ('maintenance','unavailable','inactive','retired')
    and id<>'00000000-0000-4000-8000-000000000015'::uuid) then raise exception 'Replacement vehicle is unavailable.'; end if;
  if p_swap_kind='customer_request' and (p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000) then
    raise exception 'Enter the agreed replacement daily rate.'; end if;
  if p_swap_kind in ('emergency','maintenance') and p_daily_rate is not null then
    raise exception 'Emergency and maintenance replacements preserve all booked pricing periods.'; end if;
  if exists(select 1 from public.rental_extension_requests where rental_id=r.id and status in ('pending','approved_pending_payment')) then
    raise exception 'Resolve the pending or approved unpaid extension before changing its vehicle.'; end if;
  perform public.rentmect_assert_swap_available(r.id,p_vehicle_id,p_effective_at,until_at);
  for p in select * from jsonb_populate_recordset(null::public.rental_pricing_periods,public.rentmect_pricing_snapshot(r.id)) order by starts_at loop
    if p.ends_at>p_effective_at then
      part:=1-public.rentmect_pricing_fraction(p.starts_at,p.ends_at,greatest(p.starts_at,p_effective_at));
      units:=p.billing_units*part;
      change:=case when p_swap_kind='customer_request' then round((p_daily_rate-p.daily_rate)*units*(1+p.markup_percentage/100),2) else 0 end;
      if round(p.rental_amount*part,2)+change<0 then raise exception 'This rate would exceed the remaining discounted charge; use an explicit credit correction.'; end if;
      delta:=delta+change; tax_delta:=tax_delta+round(change*0.0635,2);
      periods:=periods||jsonb_build_array(jsonb_build_object('from',greatest(p.starts_at,p_effective_at),'until',p.ends_at,
        'old_rate',p.daily_rate,'new_rate',case when p_swap_kind='customer_request' then p_daily_rate else p.daily_rate end,
        'billing_units',units,'rental_delta',change,'tax_delta',round(change*0.0635,2)));
    end if;
  end loop;
  invoice:=public.rentmect_rental_invoice_total(r.id); paid:=public.rentmect_rental_net_paid_amount(r.id);
  select coalesce(sum(total_amount),0) into additional from public.rental_charge_items where rental_id=r.id
    and not coalesce(included_in_initial_payment,false) and charge_type not in ('rental_amendment','rental_installment')
    and status in ('pending','checkout_open','failed');
  fingerprint:=md5(additional::text||to_jsonb(r)::text||public.rentmect_pricing_snapshot(r.id)::text||paid::text);
  return jsonb_build_object('rental_id',r.id,'effective_at',p_effective_at,'recorded_at',now(),'periods',periods,
    'invoice_before',invoice,'invoice_after',invoice+delta+tax_delta,'rental_delta',delta,'tax_delta',tax_delta,
    'total_delta',delta+tax_delta,'previous_balance',greatest(0,invoice-paid)+additional,'balance_due',greatest(0,invoice+delta+tax_delta-paid)+additional,
    'credit_due',greatest(0,paid-invoice-delta-tax_delta),'deposit_held',coalesce(r.deposit_held_amount,0),
    'requires_customer_resign',coalesce(r.agreement_signed,false),'revision',fingerprint,'pricing_preserved',p_swap_kind<>'customer_request');
end; $$;

create function public.admin_apply_vehicle_swap(p_rental_id uuid,p_vehicle_id uuid,p_effective_at timestamptz,
  p_swap_kind text,p_reason text,p_daily_rate numeric,p_idempotency_key uuid,p_expected_revision text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare q jsonb; req jsonb; prior public.rental_vehicle_swaps%rowtype; p record; fraction numeric;
  a public.rental_vehicle_assignments%rowtype; settlement jsonb;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
  if p_idempotency_key is null then raise exception 'Idempotency key is required.'; end if;
  perform 1 from public.rentals where id=p_rental_id for update;
  req:=jsonb_build_object('rental_id',p_rental_id,'vehicle_id',p_vehicle_id,'effective_at',p_effective_at,
    'swap_kind',p_swap_kind,'reason',trim(p_reason),'daily_rate',p_daily_rate);
  select * into prior from public.rental_vehicle_swaps where id=p_idempotency_key;
  if found then
    if prior.request is distinct from req then raise exception 'Idempotency key already used for a different swap.'; end if;
    return prior.financial_effect||jsonb_build_object('idempotent_replay',true);
  end if;
  if exists(select 1 from public.rental_charge_items where rental_id=p_rental_id and charge_type in ('rental_amendment','rental_installment') and status in ('pending','checkout_open','failed') and (status='checkout_open' or stripe_checkout_session_id is not null or stripe_payment_intent_id is not null))
    or exists(select 1 from public.rentals where id=p_rental_id and paid_at is null and (stripe_checkout_session_id is not null or stripe_payment_intent_id is not null)) then
    raise exception 'Expire the open payment attempt through the protected swap action before saving.';
  end if;
  q:=public.admin_preview_vehicle_swap(p_rental_id,p_vehicle_id,p_effective_at,p_swap_kind,p_reason,p_daily_rate);
  if p_expected_revision is distinct from q->>'revision' then raise exception 'Rental or payments changed. Review the swap again.'; end if;
  perform public.rentmect_initialize_pricing_periods(p_rental_id);
  insert into public.rental_vehicle_swaps(id,rental_id,vehicle_id,effective_at,actor_id,swap_kind,reason,request,financial_effect)
    values(p_idempotency_key,p_rental_id,p_vehicle_id,p_effective_at,auth.uid(),p_swap_kind,trim(p_reason),req,q);
  if p_swap_kind='customer_request' then
    for p in select * from public.rental_pricing_periods where rental_id=p_rental_id and ends_at>p_effective_at order by starts_at loop
      fraction:=public.rentmect_pricing_fraction(p.starts_at,p.ends_at,greatest(p.starts_at,p_effective_at));
      if fraction>0 then
        update public.rental_pricing_periods set ends_at=p_effective_at,billing_units=p.billing_units*fraction,
          rental_amount=round(p.rental_amount*fraction,2),tax_amount=round(p.tax_amount*fraction,2) where id=p.id;
        insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source)
        values(p_rental_id,p_effective_at,p.ends_at,p_daily_rate,p.billing_units*(1-fraction),p.markup_percentage,
          p.rental_amount-round(p.rental_amount*fraction,2)+round((p_daily_rate-p.daily_rate)*p.billing_units*(1-fraction)*(1+p.markup_percentage/100),2),
          p.tax_amount-round(p.tax_amount*fraction,2)+round(round((p_daily_rate-p.daily_rate)*p.billing_units*(1-fraction)*(1+p.markup_percentage/100),2)*0.0635,2),'swap');
      else
        update public.rental_pricing_periods set daily_rate=p_daily_rate,
          rental_amount=p.rental_amount+round((p_daily_rate-p.daily_rate)*p.billing_units*(1+p.markup_percentage/100),2),
          tax_amount=p.tax_amount+round(round((p_daily_rate-p.daily_rate)*p.billing_units*(1+p.markup_percentage/100),2)*0.0635,2)
          where id=p.id;
      end if;
    end loop;
  end if;
  select * into strict a from public.rental_vehicle_assignments where rental_id=p_rental_id order by assigned_from desc limit 1;
  update public.rental_vehicle_assignments set assigned_until=p_effective_at where id=a.id;
  insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source,created_by,swap_id)
    values(p_rental_id,p_vehicle_id,p_effective_at,a.assigned_until,'active_swap',auth.uid(),p_idempotency_key);
  perform set_config('rentmect.vehicle_swap',p_idempotency_key::text,true);
  update public.rentals set vehicle_id=p_vehicle_id,
    agreement_signed=false,agreement_signed_at=null,agreement_signature_name=null,agreement_ip=null,agreement_user_agent=null,
    rental_total=(select sum(rental_amount) from public.rental_pricing_periods where rental_id=p_rental_id),
    tax_amount=(select sum(tax_amount) from public.rental_pricing_periods where rental_id=p_rental_id),updated_at=now()
    where id=p_rental_id;
  perform set_config('rentmect.vehicle_swap','',true);
  settlement:=public.sync_rental_remaining_balance(p_rental_id,auth.uid());
  insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
    select id,user_id,auth.uid(),'vehicle_swap_recorded',req||q||jsonb_build_object('swap_id',p_idempotency_key,'settlement',settlement)
    from public.rentals where id=p_rental_id;
  return q||jsonb_build_object('settlement',settlement,'idempotent_replay',false);
end; $$;


-- The final BEFORE trigger freezes the accepted quote after the legacy age and
-- elapsed-day triggers. A fleet price change cannot alter a submitted quote.
create function public.rentmect_freeze_extension_quote()
returns trigger language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; rate numeric;
begin
  select * into strict r from public.rentals where id=new.rental_id for update;
  if tg_op='INSERT' then
    select daily_rate into rate from public.vehicles where id=case when new.request_kind='switch_car_continuation'
      then new.replacement_vehicle_id else r.vehicle_id end;
    new.agreed_daily_rate:=rate;
    new.agreed_markup_percentage:=coalesce(r.under_25_markup_percentage,0);
  elsif new.agreed_daily_rate is distinct from old.agreed_daily_rate
    or new.agreed_markup_percentage is distinct from old.agreed_markup_percentage then
    if current_setting('rentmect.extension_rate',true) is distinct from new.id::text then
      raise exception 'Use the reviewed extension rate agreement.'; end if;
  end if;
  if tg_op='UPDATE' and old.status in ('approved_pending_payment','activated') then
    if (new.requested_return_date,new.requested_return_time,new.original_return_date,new.original_return_time,
        new.replacement_vehicle_id,new.request_kind,new.extension_rental_amount,new.extension_tax_amount,new.extension_total_amount)
      is distinct from (old.requested_return_date,old.requested_return_time,old.original_return_date,old.original_return_time,
        old.replacement_vehicle_id,old.request_kind,old.extension_rental_amount,old.extension_tax_amount,old.extension_total_amount) then
      raise exception 'An approved extension quote is immutable; cancel it and quote a new request.'; end if;
  end if;
  if new.status='approved_pending_payment' and (tg_op='INSERT' or old.status is distinct from new.status) then
    if (new.original_return_date,new.original_return_time) is distinct from (r.return_date,r.return_time) then
      raise exception 'The rental return changed. Request a fresh extension quote.'; end if;
    -- Pending requests created before this migration get their quote at approval.
    if new.agreed_daily_rate is null then
      select daily_rate into new.agreed_daily_rate from public.vehicles where id=case when new.request_kind='switch_car_continuation'
        then new.replacement_vehicle_id else r.vehicle_id end;
      new.agreed_markup_percentage:=coalesce(r.under_25_markup_percentage,0);
    end if;
    new.extension_days:=public.rentmect_billable_days(new.original_return_date,new.original_return_time,new.requested_return_date,new.requested_return_time);
    new.extension_rental_amount:=round(new.agreed_daily_rate*new.extension_days*(1+new.agreed_markup_percentage/100),2);
    new.extension_tax_amount:=round(new.extension_rental_amount*0.0635,2);
    new.extension_total_amount:=new.extension_rental_amount+new.extension_tax_amount+coalesce(new.extension_deposit_amount,0);
  end if;
  return new;
end; $$;
create trigger zzzz_freeze_extension_quote before insert or update on public.rental_extension_requests
for each row execute function public.rentmect_freeze_extension_quote();

create function public.admin_agree_extension_rate(p_extension_request_id uuid,p_daily_rate numeric,p_reason text)
returns public.rental_extension_requests language plpgsql security definer set search_path=public as $$
declare e public.rental_extension_requests%rowtype;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
  if p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000 or length(trim(coalesce(p_reason,'')))<10 then
    raise exception 'An agreed rate and specific reason are required.'; end if;
  select * into strict e from public.rental_extension_requests where id=p_extension_request_id for update;
  if e.status<>'pending' then raise exception 'Agree the rate before approving the extension.'; end if;
  perform set_config('rentmect.extension_rate',e.id::text,true);
  update public.rental_extension_requests set agreed_daily_rate=p_daily_rate,pricing_reason=trim(p_reason),
    agreed_markup_percentage=coalesce(agreed_markup_percentage,(select coalesce(under_25_markup_percentage,0) from public.rentals where id=e.rental_id))
    where id=e.id returning * into e;
  perform set_config('rentmect.extension_rate','',true);
  insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
    values(e.rental_id,e.user_id,auth.uid(),'extension_rate_agreed',jsonb_build_object('extension_id',e.id,'rate',p_daily_rate,'reason',trim(p_reason)));
  return e;
end; $$;

-- Preserve original capture, credit paid extensions exactly once, and continue
-- honoring rental refunds, external refunds, and cancelled-deposit refunds.
create or replace function public.rentmect_rental_net_paid_amount(p_rental_id uuid)
returns numeric language plpgsql stable security definer set search_path=public as $$
declare r public.rentals%rowtype; initial_paid numeric:=0; balance_paid numeric; extensions_paid numeric;
  refunds numeric; external_refunds numeric; deposit_refunds numeric:=0;
begin
  select * into r from public.rentals where id=p_rental_id;
  if not found then return 0; end if;
  if r.paid_at is not null then initial_paid:=greatest(0,coalesce(r.payment_amount_cents,0)/100.0); end if;
  select coalesce(sum(coalesce(payment_amount_cents,round(total_amount*100)::integer))/100.0,0) into balance_paid
    from public.rental_charge_items where rental_id=r.id and charge_type='rental_amendment' and status='paid';
  select coalesce(sum(coalesce(payment_amount_cents/100.0,extension_total_amount)),0) into extensions_paid
    from public.rental_extension_requests where rental_id=r.id and request_kind='same_vehicle_extension' and status='activated' and payment_status='paid';
  select coalesce(sum(f.amount),0) into refunds from public.rental_payment_refunds f where f.rental_id=r.id
    and f.status in ('processing','pending','succeeded') and (f.extension_request_id is null or exists(
      select 1 from public.rental_extension_requests e where e.id=f.extension_request_id and e.rental_id=r.id and e.request_kind='same_vehicle_extension'));
  select coalesce(sum(amount),0) into external_refunds from public.rental_external_payment_actions where rental_id=r.id and action_type='refund';
  if r.cancelled_before_pickup_at is not null then deposit_refunds:=coalesce(r.deposit_released_amount,0); end if;
  return greatest(0,round(initial_paid+balance_paid+extensions_paid-refunds-external_refunds-deposit_refunds,2));
end; $$;

create function public.rentmect_guard_dated_rental()
returns trigger language plpgsql security definer set search_path=public as $$
declare e public.rental_extension_requests%rowtype; managed boolean; swapping boolean;
begin
  managed:=exists(select 1 from public.rental_pricing_periods where rental_id=old.id);
  swapping:=exists(select 1 from public.rental_vehicle_swaps where id::text=current_setting('rentmect.vehicle_swap',true)
    and rental_id=old.id and vehicle_id=new.vehicle_id);
  if old.status in ('active','rented','overdue','return_initiated','completed') or old.starting_mileage is not null or managed then
    if (new.pickup_date,new.pickup_time) is distinct from (old.pickup_date,old.pickup_time) then raise exception 'The original rental start cannot be changed after pickup.'; end if;
    if new.vehicle_id is distinct from old.vehicle_id and not swapping then raise exception 'Use the dedicated vehicle swap workflow with an effective time.'; end if;
  end if;
  if (new.return_date,new.return_time) is distinct from (old.return_date,old.return_time)
    and (managed or old.status in ('active','rented','overdue','return_initiated')) then
    select * into e from public.rental_extension_requests where rental_id=old.id
      and id::text=current_setting('rentmect.extension_activation',true)
      and status='approved_pending_payment' and request_kind='same_vehicle_extension'
      and (original_return_date,original_return_time)=(old.return_date,old.return_time)
      and (requested_return_date,requested_return_time)=(new.return_date,new.return_time) for update;
    if not found then raise exception 'Use a separately quoted extension to change a started rental return.'; end if;
    perform public.rentmect_initialize_pricing_periods(old.id);
    insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source,extension_request_id)
      values(old.id,public.rentmect_rental_timestamp(old.return_date,old.return_time) at time zone 'America/New_York',
        public.rentmect_rental_timestamp(new.return_date,new.return_time) at time zone 'America/New_York',
        coalesce(e.agreed_daily_rate,e.extension_rental_amount/nullif(e.extension_days,0)/(1+coalesce(old.under_25_markup_percentage,0)/100)),
        e.extension_days,coalesce(e.agreed_markup_percentage,old.under_25_markup_percentage,0),e.extension_rental_amount,e.extension_tax_amount,'extension',e.id);
    new.rental_total:=old.rental_total+e.extension_rental_amount;
    new.tax_amount:=old.tax_amount+e.extension_tax_amount;
  elsif (managed or old.status in ('active','rented','overdue','return_initiated','completed')) and not swapping and (new.rental_total,new.tax_amount,new.base_rental_total,new.discount_amount,new.manual_discount_amount)
    is distinct from (old.rental_total,old.tax_amount,old.base_rental_total,old.discount_amount,old.manual_discount_amount) then
    raise exception 'Dated rental pricing cannot be overwritten by a whole-rental edit.';
  end if;
  return new;
end; $$;
create trigger aaaa_guard_dated_rental before update on public.rentals for each row execute function public.rentmect_guard_dated_rental();

-- Existing activation functions keep all payment and insurance validations.
-- Mark only the transaction in which they activate the accepted extension.
do $migration$
declare name text; definition text;
begin
  foreach name in array array['record_admin_local_rental_extension_payment','record_stripe_checkout_payment'] loop
    select pg_get_functiondef(p.oid) into strict definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=name;
    if position('perform public.release_extension_calendar_hold(v_request.id);' in definition)=0 then
      raise exception 'Review changed extension activation function: %',name; end if;
    definition:=replace(definition,'perform public.release_extension_calendar_hold(v_request.id);',
      'perform public.release_extension_calendar_hold(v_request.id);'||chr(10)||
      'perform set_config(''rentmect.extension_activation'',v_request.id::text,true);');
    execute definition;
  end loop;
  select pg_get_functiondef('public.sync_balance_after_rental_invoice_change()'::regprocedure) into definition;
  definition:=replace(definition,'begin','begin'||chr(10)||
    '  if exists(select 1 from public.rental_extension_requests where rental_id=new.id and id::text=current_setting(''rentmect.extension_activation'',true) and status=''approved_pending_payment'') then return new; end if;');
  execute definition;
  select pg_get_functiondef('public.apply_rentmect_rental_pricing()'::regprocedure) into definition;
  definition:=replace(definition,'begin','begin'||chr(10)||
    '  if tg_op = ''UPDATE'' and exists(select 1 from public.rental_pricing_periods where rental_id=old.id) then return new; end if;');
  execute definition;
end; $migration$;

create function public.rentmect_sync_extension_balance()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.request_kind='same_vehicle_extension' and new.status='activated' and new.payment_status='paid' then
    perform public.sync_rental_remaining_balance(new.rental_id,auth.uid());
  end if;
  return new;
end; $$;
create trigger zzzz_sync_extension_balance after update of status,payment_status on public.rental_extension_requests
for each row execute function public.rentmect_sync_extension_balance();

-- Account, invoice, and extension quotes share this same payment calculation.
create function public.get_rental_account(p_rental_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r public.rentals%rowtype; invoice numeric; paid numeric; additional numeric;
begin
  select * into r from public.rentals where id=p_rental_id and (user_id=auth.uid() or public.is_admin());
  if not found then raise exception 'Rental not found.'; end if;
  invoice:=public.rentmect_rental_invoice_total(r.id); paid:=public.rentmect_rental_net_paid_amount(r.id);
  select coalesce(sum(total_amount),0) into additional from public.rental_charge_items where rental_id=r.id
    and not coalesce(included_in_initial_payment,false) and charge_type not in ('rental_amendment','rental_installment')
    and status in ('pending','checkout_open','failed');
  return jsonb_build_object('invoice_total',invoice,'net_paid',paid,'balance_due',greatest(0,invoice-paid),
    'additional_balance_due',additional,'total_balance_due',greatest(0,invoice-paid)+additional,
    'credit_due',greatest(0,paid-invoice),'deposit_held',coalesce(r.deposit_held_amount,0),
    'pricing_periods',coalesce((select jsonb_agg(p order by starts_at) from public.rental_pricing_periods p where rental_id=r.id),'[]'),
    'vehicle_assignments',coalesce((select jsonb_agg(a order by assigned_from) from public.rental_vehicle_assignments a where rental_id=r.id),'[]'),
    'swaps',coalesce((select jsonb_agg(s order by effective_at) from public.rental_vehicle_swaps s where rental_id=r.id),'[]'));
end; $$;

-- Retain the deployed quote's age/deposit/cutoff rules and add the ledger totals.
alter function public.rentmect_build_extension_quote(uuid,uuid,text,date,text) rename to rentmect_build_extension_quote_before_periods;
create function public.rentmect_build_extension_quote(p_rental_id uuid,p_vehicle_id uuid,p_request_kind text,p_requested_return_date date,p_requested_return_time text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q jsonb; a jsonb;
begin
  q:=public.rentmect_build_extension_quote_before_periods(p_rental_id,p_vehicle_id,p_request_kind,p_requested_return_date,p_requested_return_time);
  a:=public.get_rental_account(p_rental_id);
  return q||jsonb_build_object('previous_unpaid_balance',(a->>'total_balance_due')::numeric,
    'total_due',(a->>'total_balance_due')::numeric+(q->>'extension_total_amount')::numeric,
    'deposit_held',(a->>'deposit_held')::numeric,
    'pricing_note','Each started 24-hour extension period is billed as a full day. This rate applies only to the added dates. Prior charges and payments stay credited.');
end; $$;

-- Validate only the replacement assignment's time window, while retaining
-- the deployed scheduling checks for every other booking path.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.enforce_rental_schedule_integrity()'::regprocedure) into definition;
  if position('requested_start := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time);' in definition)=0 then
    raise exception 'Review changed schedule integrity function before migrating.'; end if;
  definition:=replace(definition,
    'requested_start := public.rentmect_rental_timestamp(new.pickup_date, new.pickup_time);',
    'requested_start := case when exists(select 1 from public.rental_pricing_periods where rental_id=new.id) then coalesce((select max(assigned_from) at time zone ''America/New_York'' from public.rental_vehicle_assignments where rental_id=new.id and vehicle_id=new.vehicle_id), public.rentmect_rental_timestamp(new.pickup_date,new.pickup_time)) else public.rentmect_rental_timestamp(new.pickup_date,new.pickup_time) end;');
  definition:=replace(definition,'public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time)',
    'coalesce((select max(assigned_from) at time zone ''America/New_York'' from public.rental_vehicle_assignments where rental_id=r.id and vehicle_id=r.vehicle_id), public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time))');
  execute definition;
end; $migration$;

-- Fail at preview as well as at write time for old portals attempting a swap.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.admin_preview_rental_amendment(uuid,uuid,date,text,date,text,numeric,numeric)'::regprocedure) into definition;
  definition:=replace(definition,'begin','begin'||chr(10)||$guard$
  if exists(select 1 from public.rentals r where r.id=p_rental_id
    and (r.status in ('active','rented','overdue','return_initiated','completed') or r.starting_mileage is not null)
    and (r.vehicle_id is distinct from p_vehicle_id or r.pickup_date is distinct from p_pickup_date or r.pickup_time is distinct from p_pickup_time
      or r.return_date is distinct from p_return_date or r.return_time is distinct from p_return_time)) then
    raise exception 'Use a dedicated vehicle swap or separately quoted extension for a started rental.';
  end if;
$guard$);
  execute definition;
end; $migration$;

create function public.admin_preview_extension_rate(p_extension_request_id uuid,p_daily_rate numeric)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare e public.rental_extension_requests%rowtype; r public.rentals%rowtype; units integer; amount numeric; tax numeric; a jsonb;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
  if p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000 then raise exception 'Enter a valid agreed daily rate.'; end if;
  select * into strict e from public.rental_extension_requests where id=p_extension_request_id;
  select * into strict r from public.rentals where id=e.rental_id;
  if e.status<>'pending' then raise exception 'Only pending extensions can be quoted.'; end if;
  units:=public.rentmect_billable_days(e.original_return_date,e.original_return_time,e.requested_return_date,e.requested_return_time);
  amount:=round(p_daily_rate*units*(1+coalesce(e.agreed_markup_percentage,r.under_25_markup_percentage,0)/100),2);
  tax:=round(amount*0.0635,2); a:=public.get_rental_account(r.id);
  return jsonb_build_object('daily_rate',p_daily_rate,'extension_days',units,'extension_total',amount+tax,
    'previous_balance',(a->>'total_balance_due')::numeric,'total_due',(a->>'total_balance_due')::numeric+amount+tax,'deposit_held',(a->>'deposit_held')::numeric);
end; $$;
revoke all on function public.admin_preview_extension_rate(uuid,numeric) from public,anon;
grant execute on function public.admin_preview_extension_rate(uuid,numeric) to authenticated;

create function public.admin_approve_extension_agreement(p_extension_request_id uuid,p_daily_rate numeric,p_reason text,p_expected_total numeric)
returns public.rental_extension_requests language plpgsql security definer set search_path=public as $$
declare e public.rental_extension_requests%rowtype; q jsonb;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
  select * into strict e from public.rental_extension_requests where id=p_extension_request_id for update;
  perform 1 from public.rentals where id=e.rental_id for update;
  q:=public.admin_preview_extension_rate(e.id,p_daily_rate);
  if p_expected_total is distinct from (q->>'total_due')::numeric then raise exception 'The balance or extension quote changed. Review it again.'; end if;
  if e.agreed_daily_rate is distinct from p_daily_rate then
    perform public.admin_agree_extension_rate(e.id,p_daily_rate,p_reason);
  end if;
  return public.decide_admin_rental_extension(e.id,true,null);
end; $$;
revoke all on function public.admin_approve_extension_agreement(uuid,numeric,text,numeric) from public,anon;
grant execute on function public.admin_approve_extension_agreement(uuid,numeric,text,numeric) to authenticated;

-- Bind the customer's submitted request to the daily rate they reviewed.
alter function public.request_customer_rental_extension(uuid,date,text,text) rename to request_customer_rental_extension_before_periods;
create function public.request_customer_rental_extension(p_rental_id uuid,p_requested_return_date date,
  p_requested_return_time text default '9:00 AM',p_customer_note text default null,p_expected_daily_rate numeric default null)
returns public.rental_extension_requests language plpgsql security definer set search_path=public as $$
declare q jsonb;
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  q:=public.rentmect_build_extension_quote(p_rental_id,(select vehicle_id from public.rentals where id=p_rental_id),
    'same_vehicle_extension',p_requested_return_date,p_requested_return_time);
  if p_expected_daily_rate is not null and p_expected_daily_rate is distinct from (q->>'daily_rate')::numeric then
    raise exception 'The quoted rate changed. Review the extension again.'; end if;
  return public.request_customer_rental_extension_before_periods(p_rental_id,p_requested_return_date,p_requested_return_time,p_customer_note);
end; $$;
revoke all on function public.request_customer_rental_extension(uuid,date,text,text,numeric) from public,anon;
grant execute on function public.request_customer_rental_extension(uuid,date,text,text,numeric) to authenticated;

revoke all on function public.request_customer_rental_extension_before_periods(uuid,date,text,text),public.rentmect_build_extension_quote_before_periods(uuid,uuid,text,date,text) from public,anon,authenticated;

-- Internal helpers must not be callable through PostgREST.
revoke all on function public.rentmect_pricing_snapshot(uuid),public.rentmect_initialize_pricing_periods(uuid),public.rentmect_pricing_fraction(timestamptz,timestamptz,timestamptz),
 public.rentmect_validate_periods(),public.rentmect_assert_swap_available(uuid,uuid,timestamptz,timestamptz),
 public.rentmect_freeze_extension_quote(),public.rentmect_guard_dated_rental(),public.rentmect_sync_extension_balance()
 from public,anon,authenticated;
revoke all on function public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric),
 public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text),
 public.admin_agree_extension_rate(uuid,numeric,text),public.get_rental_account(uuid),
 public.rentmect_build_extension_quote(uuid,uuid,text,date,text) from public,anon;
grant execute on function public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric),
 public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text),
 public.admin_agree_extension_rate(uuid,numeric,text),public.get_rental_account(uuid),
 public.rentmect_build_extension_quote(uuid,uuid,text,date,text) to authenticated;
notify pgrst,'reload schema';
commit;
