begin;
set local lock_timeout='5s';
-- Existing pending requests keep their original immutable allocation. New UI
-- requests declare this policy and cannot apply booking money to rent first.
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.service_prepare_external_payment(uuid,uuid,uuid,jsonb)'::regprocedure) into d;
 marker:='parts:=rentmect_payment_due_parts(r.id);';
 if position(marker in d)=0 then raise exception 'Review payment allocation contract.'; end if;
 d:=replace(d,marker,marker||$patch$
  if p_request->>'allocationPriority'='deposit_first' and funding<>'credit'
     and rent_cents>deposit_cents and deposit_cents<(parts->>'depositDueCents')::integer then
    raise exception 'Fund the security deposit before applying money to rental.';
  end if;
$patch$);
 execute d;
end $$;

-- Restricted reconciliation of an untouched legacy external booking receipt.
-- This changes classification only, preserving the payment, its date and total.
create function public.service_reclassify_legacy_deposit(p_receipt_id uuid,p_deposit_cents integer,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r external_payment_receipts%rowtype; c rental_charge_items%rowtype; rental rentals%rowtype;
 before_balance numeric; prior text; req jsonb; new_result jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 if p_deposit_cents is null or p_deposit_cents<=0 or length(trim(coalesce(p_reason,'')))<10 then raise exception 'Deposit amount and audit reason required.'; end if;
 select * into strict rental from rentals where id=(select rental_id from external_payment_receipts where id=p_receipt_id) for update;
 select * into strict r from external_payment_receipts where id=p_receipt_id for update;
 if exists(select 1 from rental_audit_events where rental_id=r.rental_id and event_type='legacy_receipt_deposit_reclassified' and event_payload->>'receipt_id'=r.id::text) then
  if r.deposit_amount_cents<>p_deposit_cents then raise exception 'Receipt was already reclassified with a different amount.'; end if;
  return r.result;
 end if;
 if r.allocation_version<>1 or r.status<>'posted' or r.funding_kind<>'external'
    or r.amount_cents<>r.rental_amount_cents or r.credit_amount_cents<>0 or r.deposit_amount_cents<>0
    or p_deposit_cents>r.amount_cents or p_deposit_cents>round(rental.security_deposit*100)
    or rental.status in ('completed','cancelled') then raise exception 'Only an untouched legacy booking receipt can be reclassified.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.rental_id and status='pending')
    or exists(select 1 from rental_deposit_allocations where holder_rental_id=r.rental_id or source_rental_id=r.rental_id)
    or exists(select 1 from rental_external_payment_actions where rental_id=r.rental_id and action_type='refund')
    or exists(select 1 from rental_payment_refunds where rental_id=r.rental_id) then
  raise exception 'Reconcile existing deposits, refunds or pending payments first.';
 end if;
 if (select count(*) from rental_charge_items where payment_receipt_id=r.id)<>1 then raise exception 'Expected one original booking payment.'; end if;
 select * into strict c from rental_charge_items where payment_receipt_id=r.id for update;
 if c.charge_type<>'rental_amendment' or c.status<>'paid' or c.payment_provider<>'local'
    or c.payment_amount_cents<>r.amount_cents or c.external_refunded_amount<>0 or c.flex_payment_receipt_id is not null then
  raise exception 'Original booking payment changed.';
 end if;
 if (select count(*) from external_payment_allocations where receipt_id=r.id)<>1
    or not exists(select 1 from external_payment_allocations where receipt_id=r.id and charge_id=c.id and amount_cents=r.amount_cents) then
  raise exception 'Original receipt allocation evidence changed.';
 end if;
 before_balance:=rentmect_rental_invoice_total(r.rental_id)-rentmect_rental_net_paid_amount(r.rental_id);
 prior:=current_setting('rentmect.external_payment_write',true);
 perform set_config('rentmect.external_payment_write','on',true);
 req:=r.request||jsonb_build_object('version',2,'funding','external','allocationPriority','deposit_first',
  'rentalAmountCents',r.rental_amount_cents-p_deposit_cents,'depositAmountCents',p_deposit_cents,'creditAmountCents',0);
 new_result:=r.result||jsonb_build_object('rentalAmountCents',r.rental_amount_cents-p_deposit_cents,'depositAmountCents',p_deposit_cents,'creditAmountCents',0,'funding','external');
 update external_payment_receipts set allocation_version=2,deposit_amount_cents=p_deposit_cents,request=req,result=new_result where id=r.id;
 update rental_charge_items set flex_payment_receipt_id=r.id where id=c.id;
 insert into rental_deposit_allocations(holder_rental_id,source_rental_id,source_kind,payment_provider,amount_held,flex_payment_receipt_id)
 values(r.rental_id,r.rental_id,'local_payment','local',p_deposit_cents/100.0,r.id);
 perform refresh_rental_deposit_summary(r.rental_id);
 if before_balance is distinct from rentmect_rental_invoice_total(r.rental_id)-rentmect_rental_net_paid_amount(r.rental_id) then
  raise exception 'Classification must not change the customer balance.';
 end if;
 insert into rental_audit_events(rental_id,event_type,event_payload) values(r.rental_id,'legacy_receipt_deposit_reclassified',
  jsonb_build_object('receipt_id',r.id,'reason',p_reason,'original_receipt',to_jsonb(r),'original_payment',to_jsonb(c),
   'deposit_amount_cents',p_deposit_cents,'balance_before',before_balance,'balance_after',before_balance,'money_moved',false));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
 return new_result;
end $$;
revoke all on function public.service_reclassify_legacy_deposit(uuid,integer,text) from public,anon,authenticated;
grant execute on function public.service_reclassify_legacy_deposit(uuid,integer,text) to service_role;
notify pgrst,'reload schema';
commit;
