begin;

-- Pricing periods already contain the original discount. The legacy reservation
-- trigger must not apply that discount again when a swap or extension updates
-- the rental's vehicle or return date.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.reprice_reserved_rental_discount()'::regprocedure) into definition;
  if position('if not coalesce(new.discount_reserved, false)' in definition)=0 then
    raise exception 'Review changed reserved discount trigger before migrating.';
  end if;
  definition:=replace(definition,'begin', 'begin'||chr(10)||
    '  if exists(select 1 from public.rental_pricing_periods where rental_id=new.id) then return new; end if;');
  execute definition;
end; $migration$;

-- A same-vehicle extension checks the added interval. After a swap, the current
-- car may legitimately have belonged to another customer earlier in this rental.
-- Apply the same boundary to preview, request, approval, and both payment paths.
do $migration$
declare name text; definition text; start_expression text; end_expression text;
begin
  foreach name in array array[
    'preview_customer_rental_extension',
    'request_customer_rental_extension_before_periods',
    'decide_admin_rental_extension',
    'record_admin_local_rental_extension_payment',
    'record_stripe_checkout_payment'
  ] loop
    select pg_get_functiondef(p.oid) into strict definition
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname=name;
    start_expression:=case when name='record_stripe_checkout_payment'
      then 'public.rentmect_rental_timestamp(v_parent_rental.pickup_date, v_parent_rental.pickup_time)'
      else 'public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time)' end;
    end_expression:=case when name='record_stripe_checkout_payment'
      then 'public.rentmect_rental_timestamp(v_parent_rental.return_date, v_parent_rental.return_time)'
      else 'public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time)' end;
    if position(start_expression in definition)=0 then
      raise exception 'Review changed extension availability function: %',name;
    end if;
    definition:=replace(definition,start_expression,end_expression);
    definition:=replace(definition,'public.rentmect_rental_timestamp(r.pickup_date, r.pickup_time)',
      'coalesce((select max(assigned_from) at time zone ''America/New_York'' from public.rental_vehicle_assignments where rental_id=r.id and vehicle_id=r.vehicle_id), public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time))');
    execute definition;
  end loop;
end; $migration$;

-- The signing screen uses the stored snapshot to detect an already signed
-- agreement. Clear the current snapshot and completion marker together; signed
-- historical documents remain in rental_signatures.
do $migration$
declare definition text;
begin
  select pg_get_functiondef('public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text)'::regprocedure) into definition;
  if position('agreement_signed=false,agreement_signed_at=null' in definition)=0 then
    raise exception 'Review changed vehicle swap agreement reset before migrating.';
  end if;
  definition:=replace(definition,'agreement_signed=false,agreement_signed_at=null',
    'agreement_signed=false,agreement_snapshot=null,agreement_hash=null,agreement_version=null,agreement_signed_at=null');
  definition:=replace(definition,'perform set_config(''rentmect.vehicle_swap'','''',true);',
    'delete from public.rental_step_completions where rental_id=p_rental_id and step_key=''agreement'';'||chr(10)||
    '  perform set_config(''rentmect.vehicle_swap'','''',true);');
  execute definition;
end; $migration$;

-- Bind a review to both its requested change and its financial state. Retiring
-- an unpaid checkout is required by the swap handler and is not a new charge;
-- those transient fields must not invalidate an otherwise unchanged review.
do $migration$
declare definition text; previous_expression text;
begin
  select pg_get_functiondef('public.admin_preview_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric)'::regprocedure) into definition;
  previous_expression:='md5(additional::text||to_jsonb(r)::text||public.rentmect_pricing_snapshot(r.id)::text||paid::text)';
  if position(previous_expression in definition)=0 then
    raise exception 'Review changed vehicle swap revision before migrating.';
  end if;
  definition:=replace(definition,previous_expression,$revision$
    md5(jsonb_build_object(
      'rental', (to_jsonb(r)-array['updated_at','stripe_checkout_session_id','stripe_payment_intent_id','payment_provider','payment_amount_cents'])
        ||jsonb_build_object('captured_amount_cents',case when r.paid_at is not null then r.payment_amount_cents else 0 end),
      'request',jsonb_build_object('vehicle_id',p_vehicle_id,'effective_at',p_effective_at,
        'swap_kind',p_swap_kind,'reason',trim(p_reason),'daily_rate',p_daily_rate),
      'assignments',(select jsonb_agg(assignment_row order by assignment_row.assigned_from,assignment_row.id)
        from public.rental_vehicle_assignments assignment_row where assignment_row.rental_id=r.id),
      'periods',public.rentmect_pricing_snapshot(r.id),'net_paid',paid,'additional_balance',additional
    )::text)
  $revision$);
  execute definition;
end; $migration$;

notify pgrst,'reload schema';
commit;
