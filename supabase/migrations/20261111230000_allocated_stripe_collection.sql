begin;
set local lock_timeout='5s';
-- Use the same allocation reservation for external and Stripe funding.
do $$ declare d text; begin
 select pg_get_functiondef('public.service_prepare_external_payment(uuid,uuid,uuid,jsonb)'::regprocedure) into d;
 if position('funding not in (''external'',''credit'')' in d)=0 then raise exception 'Review allocation preparation before enabling Stripe.'; end if;
 execute replace(d,'funding not in (''external'',''credit'')','funding not in (''external'',''credit'',''stripe'')');
 select pg_get_functiondef('public.service_finish_external_payment(uuid,uuid,boolean)'::regprocedure) into d;
 d:=replace(d,'if receipt.funding_kind=''stripe'' then raise exception ''Provider confirmation is required.''; end if;',
 'if receipt.funding_kind=''stripe'' and current_setting(''rentmect.verified_stripe_receipt'',true) is distinct from receipt.id::text then raise exception ''Provider confirmation is required.''; end if;');
 d:=replace(d,'if receipt.rental_amount_cents>0 or receipt.credit_amount_cents>0 or receipt.funding_kind=''credit'' then',
 'if receipt.funding_kind<>''stripe'' and (receipt.rental_amount_cents>0 or receipt.credit_amount_cents>0 or receipt.funding_kind=''credit'') then');
 d:=replace(d,'if jsonb_array_length(receipt.request->''charges'')>0 then','if receipt.funding_kind<>''stripe'' and jsonb_array_length(receipt.request->''charges'')>0 then');
 d:=replace(d,'payment_provider=case when allocated_deposit_cents>0 then ''deposit'' else ''local'' end',
 'payment_provider=case when allocated_deposit_cents>0 then ''deposit'' when receipt.funding_kind=''stripe'' then ''stripe'' else ''local'' end');
 -- Rental cash accounting is settled by its existing RPC, then linked to the verified provider receipt.
 d:=replace(d,'update rental_deposit_allocations set flex_payment_receipt_id=p_id where holder_rental_id=receipt.rental_id and not(id=any(prior_deposits));', $patch$
  update rental_deposit_allocations set flex_payment_receipt_id=p_id where holder_rental_id=receipt.rental_id and not(id=any(prior_deposits));
  if receipt.funding_kind='stripe' then
   update rental_charge_items set payment_provider='stripe',stripe_payment_intent_id=receipt.stripe_payment_intent_id,
    stripe_checkout_session_id=receipt.stripe_checkout_session_id,external_payment_method=null where id=paid_id;
   update rental_deposit_allocations set payment_provider='stripe',stripe_payment_intent_id=receipt.stripe_payment_intent_id
    where holder_rental_id=receipt.rental_id and not(id=any(prior_deposits));
  end if;$patch$);
 execute d;
end $$;

create function public.service_bind_allocated_stripe(p_id uuid,p_session text default null,p_intent text default null,p_url text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r external_payment_receipts%rowtype;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=p_id) for update;
 select * into strict r from external_payment_receipts where id=p_id for update;
 if r.funding_kind<>'stripe' or r.status<>'pending' then raise exception 'Stripe reservation is no longer pending.'; end if;
 if r.stripe_checkout_session_id is not null and r.stripe_checkout_session_id is distinct from p_session then raise exception 'Another checkout already owns this receipt.'; end if;
 if r.stripe_payment_intent_id is not null and r.stripe_payment_intent_id is distinct from p_intent then raise exception 'Another card attempt already owns this receipt.'; end if;
 update external_payment_receipts set stripe_checkout_session_id=p_session,stripe_payment_intent_id=p_intent,
 result=result||jsonb_build_object('url',p_url,'sessionId',p_session,'paymentIntentId',p_intent) where id=p_id returning * into r;
 return r.result;
end $$;

create function public.service_confirm_allocated_stripe(p_id uuid,p_session text,p_intent text,p_amount integer,p_currency text,p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r external_payment_receipts%rowtype; prior text; result jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=p_id) for update;
 select * into strict r from external_payment_receipts where id=p_id for update;
 if r.funding_kind<>'stripe' then raise exception 'This is not a Stripe allocation receipt.'; end if;
 if r.status in ('posted','refunded') then
  if p_intent is distinct from r.stripe_payment_intent_id or p_amount is distinct from r.amount_cents then raise exception 'Stripe confirmation differs from the posted receipt.'; end if;
  return r.result;
 end if;
 if r.status<>'pending' then raise exception 'This receipt is not pending.'; end if;
 if r.stripe_checkout_session_id is distinct from p_session or
  (r.stripe_payment_intent_id is not null and r.stripe_payment_intent_id is distinct from p_intent) then raise exception 'Stripe collection does not match its reservation.'; end if;
 if not p_cancel and (nullif(p_intent,'') is null or p_amount is distinct from r.amount_cents or lower(coalesce(p_currency,''))<>'usd') then raise exception 'Verified Stripe amount and currency must match the allocation.'; end if;
 if not p_cancel then update external_payment_receipts set stripe_payment_intent_id=p_intent where id=p_id; end if;
 prior:=current_setting('rentmect.verified_stripe_receipt',true);perform set_config('rentmect.verified_stripe_receipt',r.id::text,true);
 result:=service_finish_external_payment(r.id,r.actor_id,p_cancel);
 perform set_config('rentmect.verified_stripe_receipt',coalesce(prior,''),true);
 return result;
end $$;
revoke all on function public.service_bind_allocated_stripe(uuid,text,text,text), public.service_confirm_allocated_stripe(uuid,text,text,integer,text,boolean) from public,anon,authenticated;
grant execute on function public.service_bind_allocated_stripe(uuid,text,text,text), public.service_confirm_allocated_stripe(uuid,text,text,integer,text,boolean) to service_role;
notify pgrst,'reload schema';
commit;
