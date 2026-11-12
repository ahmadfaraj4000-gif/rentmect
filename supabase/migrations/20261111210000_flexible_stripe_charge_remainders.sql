begin;
set local lock_timeout='5s';
-- Permit the existing service-only checkout orchestration to reserve a managed
-- charge. No client can change allocations or mark the charge paid this way.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.guard_flexible_payment_allocations()'::regprocedure) into definition;
 marker:=' if old.allocation_managed and new.status=old.status and';
 if position(marker in definition)=0 then raise exception 'Review changed allocation guard.'; end if;
 definition:=replace(definition,marker,$patch$
 if old.allocation_managed and auth.role()='service_role'
  and old.status in ('pending','failed','checkout_open') and new.status in ('pending','failed','checkout_open')
  and (to_jsonb(new)-array['status','checkout_creation_token','stripe_checkout_session_id','stripe_payment_intent_id','stripe_customer_id','payment_provider','payment_amount_cents','payment_currency','admin_charge_attempts','admin_charge_attempted_at','last_admin_charge_error','updated_at'])
   is not distinct from (to_jsonb(old)-array['status','checkout_creation_token','stripe_checkout_session_id','stripe_payment_intent_id','stripe_customer_id','payment_provider','payment_amount_cents','payment_currency','admin_charge_attempts','admin_charge_attempted_at','last_admin_charge_error','updated_at'])
  and (new.payment_amount_cents is not distinct from old.payment_amount_cents or new.payment_amount_cents=round(rentmect_charge_remaining_amount(old)*100)) then
   return new;
 end if;
 if old.allocation_managed and new.status=old.status and$patch$);
 execute definition;
end $$;
-- Preserve the immutable deposit application while collecting only its remainder.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.protect_deposit_settlement()'::regprocedure) into definition;
 marker:='   if old.allocation_managed and new.allocated_deposit_cents=old.allocated_deposit_cents';
 if position(marker in definition)=0 then raise exception 'Review changed mixed deposit protection.'; end if;
 definition:=replace(definition,marker,$patch$
   if old.allocation_managed and auth.role()='service_role'
    and new.allocated_deposit_cents=old.allocated_deposit_cents and new.payment_provider='deposit'
    and (to_jsonb(new)-array['status','checkout_creation_token','stripe_checkout_session_id','stripe_payment_intent_id','stripe_customer_id','payment_amount_cents','payment_currency','admin_charge_attempts','admin_charge_attempted_at','last_admin_charge_error','updated_at'])
      is not distinct from (to_jsonb(old)-array['status','checkout_creation_token','stripe_checkout_session_id','stripe_payment_intent_id','stripe_customer_id','payment_amount_cents','payment_currency','admin_charge_attempts','admin_charge_attempted_at','last_admin_charge_error','updated_at'])
    and old.status in ('pending','failed','checkout_open') and new.status in ('pending','failed','checkout_open') then return new; end if;
   if old.allocation_managed and new.allocated_deposit_cents=old.allocated_deposit_cents$patch$);
 -- Trusted posting changes the Stripe references as well as allocation counters.
 definition:=replace(definition,
  '''allocated_payment_cents'',''allocated_waiver_cents'',''status'',''payment_amount_cents'',''paid_at'',''updated_at'',''last_admin_charge_error''',
  '''allocated_payment_cents'',''allocated_waiver_cents'',''status'',''payment_amount_cents'',''payment_currency'',''stripe_checkout_session_id'',''stripe_payment_intent_id'',''paid_at'',''updated_at'',''last_admin_charge_error''');
 execute definition;
end $$;
alter function public.record_stripe_rental_charge_payment(uuid,text,text,integer,text) rename to record_stripe_rental_charge_payment_v1;
revoke all on function public.record_stripe_rental_charge_payment_v1(uuid,text,text,integer,text) from public,anon,authenticated;
create function public.record_stripe_rental_charge_payment(p_charge_id uuid,p_checkout_session_id text,p_payment_intent_id text,p_amount_total integer,p_currency text)
returns public.rental_charge_items language plpgsql security definer set search_path=public as $$
declare c rental_charge_items%rowtype; r external_payment_receipts%rowtype; receipt_id uuid:=gen_random_uuid(); prior text; expected integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform 1 from rentals where id=(select rental_id from rental_charge_items where id=p_charge_id) for update;
 select * into strict c from rental_charge_items where id=p_charge_id for update;
 if not c.allocation_managed then return record_stripe_rental_charge_payment_v1(p_charge_id,p_checkout_session_id,p_payment_intent_id,p_amount_total,p_currency); end if;
 if nullif(p_payment_intent_id,'') is null or lower(coalesce(p_currency,''))<>'usd' or p_amount_total is null or p_amount_total<=0 then raise exception 'Verified Stripe payment details required.'; end if;
 select * into r from external_payment_receipts where stripe_payment_intent_id=p_payment_intent_id;
 if found then
  if r.rental_id<>c.rental_id or r.amount_cents<>p_amount_total or not exists(select 1 from external_payment_allocations where external_payment_allocations.receipt_id=r.id and charge_id=c.id) then raise exception 'Stripe payment already belongs to another allocation.'; end if;
  return c;
 end if;
 expected:=round(rentmect_charge_remaining_amount(c)*100);
 if c.status not in ('pending','failed','checkout_open') or p_amount_total<>expected then raise exception 'Stripe payment does not match the remaining allocated charge balance.'; end if;
 if c.checkout_creation_token is not null then raise exception 'Checkout creation is unresolved; retry confirmation.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=c.rental_id and status='pending') then raise exception 'Resolve the pending external receipt before confirming Stripe.'; end if;
 if nullif(c.stripe_payment_intent_id,'') is not null and c.stripe_payment_intent_id<>p_payment_intent_id then raise exception 'Stripe intent does not match the reserved collection.'; end if;
 if c.stripe_checkout_session_id like 'cs_%' and c.stripe_checkout_session_id is distinct from p_checkout_session_id then raise exception 'Stripe checkout does not match the reserved collection.'; end if;
 if nullif(c.stripe_payment_intent_id,'') is null and nullif(c.stripe_checkout_session_id,'') is null then raise exception 'No Stripe collection is reserved for this charge.'; end if;
 prior:=current_setting('rentmect.external_payment_write',true);perform set_config('rentmect.external_payment_write','on',true);
 insert into external_payment_receipts(id,rental_id,actor_id,request,amount_cents,rental_amount_cents,payment_method,received_date,status,posted_at,allocation_version,funding_kind,credit_amount_cents,stripe_checkout_session_id,stripe_payment_intent_id,result)
 values(receipt_id,c.rental_id,c.user_id,jsonb_build_object('version',2,'funding','stripe','chargeId',c.id),p_amount_total,0,'card',(now() at time zone 'America/New_York')::date,'posted',now(),2,'stripe',0,p_checkout_session_id,p_payment_intent_id,jsonb_build_object('status','posted','receiptId',receipt_id,'amountCents',p_amount_total));
 insert into external_payment_allocations values(receipt_id,c.id,p_amount_total,to_jsonb(c));
 update rental_charge_items set allocated_payment_cents=allocated_payment_cents+p_amount_total,status='paid',payment_provider=case when allocated_deposit_cents>0 then 'deposit' else 'stripe' end,
 payment_amount_cents=p_amount_total,payment_currency='usd',paid_at=now(),stripe_checkout_session_id=p_checkout_session_id,stripe_payment_intent_id=p_payment_intent_id,last_admin_charge_error=null,updated_at=now() where id=c.id returning * into c;
 insert into rental_audit_events(rental_id,user_id,event_type,event_payload) values(c.rental_id,c.user_id,'stripe_allocated_charge_paid',jsonb_build_object('receipt_id',receipt_id,'charge_id',c.id,'amount_cents',p_amount_total,'payment_intent_id',p_payment_intent_id));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
 return c;
end $$;
revoke all on function public.record_stripe_rental_charge_payment(uuid,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.record_stripe_rental_charge_payment(uuid,text,text,integer,text) to service_role;
-- Retire only outstanding provider attempts, never a previously posted Stripe receipt.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.service_prepare_external_payment(uuid,uuid,uuid,jsonb)'::regprocedure) into definition;
 marker:=' if exists(select 1 from jsonb_array_elements(paths) e where';
 if position(marker in definition)=0 then raise exception 'Review changed external collection path preparation.'; end if;
 definition:=replace(definition,marker,$patch$
 paths:=(select coalesce(jsonb_agg(case when (e->>'allocation_managed')::boolean and exists(
  select 1 from external_payment_receipts pr join external_payment_allocations pa on pa.receipt_id=pr.id
  where pr.status='posted' and pr.funding_kind='stripe' and pa.charge_id=(e->>'id')::uuid
  and (pr.stripe_payment_intent_id=e->>'stripe_payment_intent_id' or pr.stripe_checkout_session_id=e->>'stripe_checkout_session_id'))
  then e-array['stripe_payment_intent_id','stripe_checkout_session_id','admin_charge_attempted_at'] else e end),'[]') from jsonb_array_elements(paths) e);
 if exists(select 1 from jsonb_array_elements(paths) e where$patch$);
 execute definition;
end $$;
-- One MVCC snapshot includes both the existing reporting sources and allocations.
alter function public.admin_payment_revenue_snapshot() rename to admin_payment_revenue_snapshot_v1;
revoke all on function public.admin_payment_revenue_snapshot_v1() from public,anon;
create function public.admin_payment_revenue_snapshot() returns jsonb
language sql stable security invoker set search_path=public as $$
 select public.admin_payment_revenue_snapshot_v1() || public.admin_flexible_payment_revenue();
$$;
revoke all on function public.admin_payment_revenue_snapshot() from public,anon;
grant execute on function public.admin_payment_revenue_snapshot() to authenticated;
notify pgrst,'reload schema';
commit;
