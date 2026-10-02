begin;

-- Staff may extend a started rental directly, leaving the added charges on its
-- ordinary balance. Customer-request approval/payment remains a separate flow.
create table public.rental_admin_extensions (
  id uuid primary key,
  rental_id uuid not null references public.rentals(id),
  actor_id uuid not null references auth.users(id),
  recorded_at timestamptz not null default now(),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  daily_rate numeric not null check (daily_rate >= 0 and daily_rate <= 100000),
  billing_units integer not null check (billing_units > 0),
  markup_percentage numeric not null,
  rental_amount numeric(12,2) not null,
  tax_amount numeric(12,2) not null,
  reason text not null check (length(trim(reason)) >= 10),
  request jsonb not null,
  financial_effect jsonb not null
);
create index on public.rental_admin_extensions(rental_id,recorded_at);
alter table public.rental_admin_extensions enable row level security;
create policy admin_extension_read on public.rental_admin_extensions for select to authenticated
  using (public.is_admin() or exists(select 1 from public.rentals r where r.id=rental_id and r.user_id=auth.uid()));
grant select on public.rental_admin_extensions to authenticated;
alter table public.rental_pricing_periods add column admin_extension_id uuid unique references public.rental_admin_extensions(id);

create function public.admin_preview_rental_extension(p_rental_id uuid,p_return_date date,p_return_time text,p_daily_rate numeric,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; a jsonb; req jsonb; units integer; amount numeric; tax numeric;
  starts timestamptz; ends timestamptz; revision text;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then
    raise exception 'Rental editing permission is required.'; end if;
  if p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000 or length(trim(coalesce(p_reason,'')))<10 then
    raise exception 'An agreed daily rate and specific reason are required.'; end if;
  if p_return_date is null or nullif(trim(p_return_time),'') is null then raise exception 'Choose the new return date and time.'; end if;
  select * into strict r from public.rentals where id=p_rental_id for update;
  if r.status not in ('active','rented','overdue') or r.inspection_completed_at is not null then
    raise exception 'Only an active rental awaiting return can be extended.'; end if;
  starts:=public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York';
  ends:=public.rentmect_rental_timestamp(p_return_date,p_return_time) at time zone 'America/New_York';
  if ends<=starts or ends<=now() then raise exception 'New return must be after the booked return and in the future.'; end if;
  if exists(select 1 from public.rental_extension_requests where rental_id=r.id and status in ('pending','approved_pending_payment')) then
    raise exception 'Resolve the existing extension request before creating another extension.'; end if;
  perform public.rentmect_assert_swap_available(r.id,r.vehicle_id,starts,ends);
  if exists(select 1 from public.rentals other where other.id<>r.id and other.user_id=r.user_id
    and other.status not in ('completed','cancelled')
    and starts<(public.rentmect_rental_timestamp(other.return_date,other.return_time) at time zone 'America/New_York')
    and ends>(public.rentmect_rental_timestamp(other.pickup_date,other.pickup_time) at time zone 'America/New_York')) then
    raise exception 'This extension overlaps another rental for this customer.'; end if;
  units:=public.rentmect_billable_days(r.return_date,r.return_time,p_return_date,p_return_time);
  amount:=round(p_daily_rate*units*(1+coalesce(r.under_25_markup_percentage,0)/100),2);
  tax:=round(amount*0.0635,2);
  a:=public.get_rental_account(r.id);
  req:=jsonb_build_object('return_date',p_return_date,'return_time',p_return_time,'daily_rate',p_daily_rate,'reason',trim(p_reason));
  revision:=md5(jsonb_build_object('rental',
    (to_jsonb(r)-array['updated_at','stripe_checkout_session_id','stripe_payment_intent_id','payment_provider','payment_amount_cents'])
      ||jsonb_build_object('captured_amount_cents',case when r.paid_at is not null then r.payment_amount_cents else 0 end),
    'request',req,'account',a)::text);
  return jsonb_build_object('revision',revision,'starts_at',starts,'ends_at',ends,'daily_rate',p_daily_rate,
    'extension_days',units,'markup_percentage',coalesce(r.under_25_markup_percentage,0),
    'rental_amount',amount,'tax_amount',tax,'extension_total',amount+tax,
    'invoice_before',(a->>'invoice_total')::numeric,'invoice_after',(a->>'invoice_total')::numeric+amount+tax,
    'previous_balance',(a->>'total_balance_due')::numeric,
    'total_due',greatest(0,(a->>'invoice_total')::numeric+amount+tax-(a->>'net_paid')::numeric)+(a->>'additional_balance_due')::numeric,
    'deposit_held',(a->>'deposit_held')::numeric);
end; $$;

-- Only a recorded, reviewed admin extension can append dates through this path.
-- The existing customer extension activation branch remains intact.
do $migration$
declare definition text; marker text;
begin
  select pg_get_functiondef('public.rentmect_guard_dated_rental()'::regprocedure) into definition;
  marker:='select * into e from public.rental_extension_requests where rental_id=old.id';
  if position(marker in definition)=0 then raise exception 'Review changed dated rental guard before migrating.'; end if;
  definition:=replace(definition,marker,$guard$
    if exists(select 1 from public.rental_admin_extensions extension
      where extension.id::text=current_setting('rentmect.admin_extension',true) and extension.rental_id=old.id
      and extension.starts_at=(public.rentmect_rental_timestamp(old.return_date,old.return_time) at time zone 'America/New_York')
      and extension.ends_at=(public.rentmect_rental_timestamp(new.return_date,new.return_time) at time zone 'America/New_York')) then
      perform public.rentmect_initialize_pricing_periods(old.id);
      insert into public.rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,
        markup_percentage,rental_amount,tax_amount,source,admin_extension_id)
        select rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,'extension',id
        from public.rental_admin_extensions where id::text=current_setting('rentmect.admin_extension',true);
      new.rental_total:=(select sum(rental_amount) from public.rental_pricing_periods where rental_id=old.id);
      new.tax_amount:=(select sum(tax_amount) from public.rental_pricing_periods where rental_id=old.id);
      return new;
    end if;
    select * into e from public.rental_extension_requests where rental_id=old.id
  $guard$);
  execute definition;
end; $migration$;

create function public.admin_apply_rental_extension(p_rental_id uuid,p_return_date date,p_return_time text,p_daily_rate numeric,
  p_reason text,p_idempotency_key uuid,p_expected_revision text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare q jsonb; req jsonb; prior public.rental_admin_extensions%rowtype; settlement jsonb;
begin
  if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then
    raise exception 'Rental editing permission is required.'; end if;
  if p_idempotency_key is null then raise exception 'An idempotency key is required.'; end if;
  perform 1 from public.rentals where id=p_rental_id for update;
  req:=jsonb_build_object('return_date',p_return_date,'return_time',p_return_time,'daily_rate',p_daily_rate,'reason',trim(p_reason));
  select * into prior from public.rental_admin_extensions where id=p_idempotency_key;
  if found then
    if prior.rental_id<>p_rental_id or prior.request is distinct from req then raise exception 'Idempotency key already used for a different extension.'; end if;
    return prior.financial_effect||jsonb_build_object('idempotent_replay',true);
  end if;
  if exists(select 1 from public.rental_charge_items where rental_id=p_rental_id
    and charge_type in ('rental_amendment','rental_installment') and status in ('pending','checkout_open','failed')
    and (status='checkout_open' or stripe_checkout_session_id is not null or stripe_payment_intent_id is not null))
    or exists(select 1 from public.rentals where id=p_rental_id and paid_at is null
      and (stripe_checkout_session_id is not null or stripe_payment_intent_id is not null)) then
    raise exception 'Expire the open payment attempt through the protected extension action before saving.';
  end if;
  q:=public.admin_preview_rental_extension(p_rental_id,p_return_date,p_return_time,p_daily_rate,p_reason);
  if p_expected_revision is distinct from q->>'revision' then raise exception 'Rental or payments changed. Review the extension again.'; end if;
  insert into public.rental_admin_extensions(id,rental_id,actor_id,starts_at,ends_at,daily_rate,billing_units,
    markup_percentage,rental_amount,tax_amount,reason,request,financial_effect)
    values(p_idempotency_key,p_rental_id,auth.uid(),(q->>'starts_at')::timestamptz,(q->>'ends_at')::timestamptz,p_daily_rate,
      (q->>'extension_days')::integer,(q->>'markup_percentage')::numeric,(q->>'rental_amount')::numeric,
      (q->>'tax_amount')::numeric,trim(p_reason),req,q);
  perform set_config('rentmect.admin_extension',p_idempotency_key::text,true);
  update public.rentals set return_date=p_return_date,return_time=p_return_time,
    -- Include totals in the UPDATE column list to run the canonical balance trigger.
    rental_total=rental_total,tax_amount=tax_amount,
    agreement_signed=false,agreement_snapshot=null,agreement_hash=null,agreement_version=null,
    agreement_signed_at=null,agreement_signature_name=null,agreement_ip=null,agreement_user_agent=null,updated_at=now()
    where id=p_rental_id;
  perform set_config('rentmect.admin_extension','',true);
  delete from public.rental_step_completions where rental_id=p_rental_id and step_key='agreement';
  settlement:=public.sync_rental_remaining_balance(p_rental_id,auth.uid());
  insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
    select id,user_id,auth.uid(),'admin_rental_extension_applied',req||q||jsonb_build_object('extension_id',p_idempotency_key,'settlement',settlement)
    from public.rentals where id=p_rental_id;
  return q||jsonb_build_object('settlement',settlement,'idempotent_replay',false);
end; $$;

revoke all on function public.admin_preview_rental_extension(uuid,date,text,numeric,text),
  public.admin_apply_rental_extension(uuid,date,text,numeric,text,uuid,text) from public,anon;
grant execute on function public.admin_preview_rental_extension(uuid,date,text,numeric,text),
  public.admin_apply_rental_extension(uuid,date,text,numeric,text,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
