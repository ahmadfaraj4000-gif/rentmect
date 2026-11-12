begin;
set local lock_timeout='5s';
create table public.payment_amount_corrections (
 id uuid primary key, rental_id uuid not null references public.rentals(id), actor_id uuid not null,
 source_type text not null, source_id uuid not null, request jsonb not null, before_snapshot jsonb not null,
 result jsonb not null, created_at timestamptz not null default now()
);
alter table public.payment_amount_corrections enable row level security;
revoke all on public.payment_amount_corrections from public,anon,authenticated;
grant select on public.payment_amount_corrections to authenticated;
create policy staff_read_payment_corrections on public.payment_amount_corrections for select to authenticated using (public.is_admin() and public.rentmect_has_permission('payment.collect'));

-- Preview and commit share the same locked calculation. A changed receipt or allocation invalidates the review.
create function public.admin_correct_payment_amount(p_source_type text,p_source_id uuid,p_request jsonb,p_key uuid,p_review_token text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rid uuid; tbl text; source jsonb; snapshot jsonb; before_cents integer; after_cents integer;
 r external_payment_receipts%rowtype; a record; plan jsonb:='[]'; entry jsonb; token text; result jsonb; saved payment_amount_corrections%rowtype;
 delta integer; remaining integer; take_cents integer; next_cents integer; rent_delta integer:=0; new_rent integer:=0; new_credit integer:=0; used_credit integer:=0;
 method text; prior text; created_receipt uuid; held numeric; original_total integer; permission text;
begin
 if not is_admin() or auth.uid() is null then raise exception 'Staff access required.'; end if;
 if not coalesce(rentmect_has_permission('payment.collect'),false) then raise exception 'Payment correction permission required.'; end if;
 select * into saved from payment_amount_corrections where id=p_key;
 if found then
  if saved.source_type<>p_source_type or saved.source_id<>p_source_id or saved.request<>p_request then raise exception 'Correction key was already used for different changes.'; end if;
  return saved.result;
 end if;
 if p_source_type='receipt' then
  select rental_id into rid from external_payment_receipts where id=p_source_id;
 else
  tbl:=case p_source_type when 'rental_charge' then 'rental_charge_items' when 'rental' then 'rentals' when 'extension' then 'rental_extension_requests' end;
  if tbl is null then raise exception 'This provider payment cannot be edited as external money.'; end if;
  execute format('select to_jsonb(t) from %I t where id=$1',tbl) into source using p_source_id;
  rid:=case when p_source_type='rental' then p_source_id else (source->>'rental_id')::uuid end;
 end if;
 perform 1 from rentals where id=rid for update;
 if not found then raise exception 'Payment not found.'; end if;
 -- Serialize retries even when two confirmations arrive together.
 select * into saved from payment_amount_corrections where id=p_key;
 if found then
  if saved.source_type<>p_source_type or saved.source_id<>p_source_id or saved.request<>p_request then raise exception 'Correction key was already used for different changes.'; end if;
  return saved.result;
 end if;
 if exists(select 1 from external_payment_receipts where rental_id=rid and status='pending') then raise exception 'Finish or cancel the pending payment before correcting this receipt.'; end if;
 if exists(select 1 from rental_charge_items where rental_id=rid and status='checkout_open') then raise exception 'Cancel the open Stripe collection before correcting this payment.'; end if;
 after_cents:=(p_request->>'amountCents')::integer;
 if after_cents is null or after_cents<1 then raise exception 'Enter the actual amount received, at least $0.01. Use reversal for a payment that was never received.'; end if;
 if length(trim(coalesce(p_request->>'reason','')))<5 then raise exception 'Enter a reason for this correction.'; end if;
 if (p_request->>'receivedDate')::date is null or (p_request->>'receivedDate')::date>(now() at time zone 'America/New_York')::date then raise exception 'Choose a received date no later than today.'; end if;
 if nullif(p_request->>'receivedTime','') is not null and (p_request->>'receivedDate')::date+(p_request->>'receivedTime')::time>now() at time zone 'America/New_York' then raise exception 'Received time cannot be in the future.'; end if;
 if length(coalesce(p_request->>'notes',''))>2000 or length(coalesce(p_request->>'reference',''))>120 then raise exception 'Payment details are too long.'; end if;
 if p_source_type='receipt' then
  select * into strict r from external_payment_receipts where id=p_source_id for update;
  if r.status<>'posted' or r.funding_kind<>'external' or r.allocation_version<>2 then raise exception 'Only posted external allocations can have their received amount corrected.'; end if;
  source:=to_jsonb(r);before_cents:=r.amount_cents;new_rent:=r.rental_amount_cents;new_credit:=r.credit_amount_cents;
  select coalesce(sum(c.amount_cents),0) into used_credit from customer_credit_applications c join external_payment_receipts used on used.id=c.receipt_id where c.source_receipt_id=r.id and used.status in ('posted','pending');
  remaining:=greatest(0,before_cents-after_cents);
  take_cents:=least(remaining,new_credit-used_credit);new_credit:=new_credit-take_cents;remaining:=remaining-take_cents;
  if after_cents>before_cents then new_credit:=new_credit+after_cents-before_cents; end if;
  for a in select x.*,c.charge_type,c.name,c.allocated_payment_cents,c.allocated_deposit_cents,c.allocated_waiver_cents,c.total_amount from external_payment_allocations x join rental_charge_items c on c.id=x.charge_id where x.receipt_id=r.id order by (c.charge_type='rental_amendment'),c.id for update of c loop
   take_cents:=least(remaining,a.amount_cents);next_cents:=a.amount_cents-take_cents;remaining:=remaining-take_cents;
   if a.charge_type='rental_amendment' then new_rent:=new_rent-take_cents;rent_delta:=rent_delta-take_cents; end if;
   plan:=plan||jsonb_build_array(jsonb_build_object('id',a.charge_id,'name',a.name,'beforeCents',a.amount_cents,'afterCents',next_cents,'rental',a.charge_type='rental_amendment','counter',a.allocated_payment_cents));
  end loop;
  if remaining>0 then raise exception 'This payment has credit already used elsewhere. Reverse those credit applications before reducing it further.'; end if;
  if exists(select 1 from rental_deposit_allocations where flex_payment_receipt_id=r.id and amount_held>new_rent/100.0) then raise exception 'The corrected rental allocation would be less than its held security deposit. Reconcile the deposit before reducing it further.'; end if;
  if exists(select 1 from jsonb_array_elements(plan) p where not(p->>'rental')::boolean) and not coalesce(rentmect_has_permission('charge.manage'),false) then raise exception 'Charge management permission required.'; end if;
 else
  execute format('select to_jsonb(t) from %I t where id=$1 for update',tbl) into source using p_source_id;
  if source->>'payment_provider' is distinct from 'local' or source->>'paid_at' is null then raise exception 'Only received external payments can be corrected. Stripe amounts must be changed by collecting or refunding money through Stripe.'; end if;
  if source->>'payment_receipt_id' is not null or source->>'external_toll_receipt_id' is not null or source->>'flex_payment_receipt_id' is not null then raise exception 'Edit the grouped payment receipt instead.'; end if;
  if coalesce((source->>'external_refunded_amount')::numeric,0)>0 or exists(select 1 from rental_external_payment_actions where rental_id=rid and action_type='refund' and (payment_charge_id=p_source_id or p_source_type<>'rental_charge')) then raise exception 'This payment has a recorded refund. Reconcile the refund before correcting its original amount.'; end if;
  before_cents:=coalesce((source->>'payment_amount_cents')::integer,round(coalesce((source->>'total_amount')::numeric,(source->>'extension_total_amount')::numeric,0)*100)::integer);
  if p_source_type='rental_charge' and source->>'charge_type' not in ('rental_amendment','rental_installment') then
   if not coalesce(rentmect_has_permission('charge.manage'),false) then raise exception 'Charge management permission required.'; end if;
   if coalesce((source->>'allocation_managed')::boolean,false) or coalesce((source->>'included_in_initial_payment')::boolean,false) then raise exception 'Edit the original payment receipt instead.'; end if;
   original_total:=round((source->>'total_amount')::numeric*100)::integer;
   new_credit:=greatest(0,after_cents-original_total);
   plan:=jsonb_build_array(jsonb_build_object('id',p_source_id,'name',source->>'name','beforeCents',before_cents,'afterCents',least(after_cents,original_total),'rental',false));
  else
   rent_delta:=after_cents-before_cents;new_rent:=after_cents;
   plan:=jsonb_build_array(jsonb_build_object('id',p_source_id,'name','Rental payment','beforeCents',before_cents,'afterCents',after_cents,'rental',true));
  end if;
 end if;
 if before_cents is distinct from (p_request->>'expectedAmountCents')::integer then raise exception 'This payment changed. Close and reopen its details before correcting it.'; end if;
 method:=coalesce(nullif(p_request->>'paymentMethod',''),source->>'payment_method',source->>'external_payment_method','other');
 if method not in ('cash','cash_app','terminal','card','bank_transfer','other') then raise exception 'Choose a valid external payment method.'; end if;
 -- Never reduce recorded cash below deposits that are still held or already committed.
 select coalesce(sum(amount_held),0) into held from rental_deposit_allocations where holder_rental_id=rid;
 if rent_delta<0 and rentmect_rental_net_paid_amount(rid)+rent_delta/100.0<held then raise exception 'The corrected rental payments would be below the security deposit already held or used. Reconcile that deposit first.'; end if;
 snapshot:=jsonb_build_object('source',source,'allocations',plan,'usedCredit',used_credit,'held',held,'netPaid',rentmect_rental_net_paid_amount(rid));
 token:=md5(snapshot::text||p_request::text);
 result:=jsonb_build_object('status','review','reviewToken',token,'beforeCents',before_cents,'afterCents',after_cents,'allocations',plan,'creditCents',new_credit,'rentalBalanceAfterCents',greatest(0,round((rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid))*100)::integer-rent_delta));
 if p_review_token is null then return result; end if;
 if token<>p_review_token then raise exception 'The payment or balance changed after review. Review the correction again.'; end if;
 prior:=current_setting('rentmect.external_payment_write',true);perform set_config('rentmect.external_payment_write','on',true);
 if p_source_type='receipt' then
  for entry in select value from jsonb_array_elements(plan) loop
   next_cents:=(entry->>'afterCents')::integer;delta:=next_cents-(entry->>'beforeCents')::integer;
   if (entry->>'rental')::boolean then
    update rental_charge_items set amount=next_cents/100.0,total_amount=next_cents/100.0,payment_amount_cents=next_cents,external_payment_method=method where id=(entry->>'id')::uuid;
   else
    update rental_charge_items set allocated_payment_cents=allocated_payment_cents+delta,payment_amount_cents=allocated_payment_cents+delta,
     status=case when allocated_payment_cents+delta+allocated_deposit_cents+allocated_waiver_cents>=round(total_amount*100) then 'paid' else 'pending' end where id=(entry->>'id')::uuid;
   end if;
   if next_cents=0 then delete from external_payment_allocations where receipt_id=r.id and charge_id=(entry->>'id')::uuid;
   else update external_payment_allocations set amount_cents=next_cents where receipt_id=r.id and charge_id=(entry->>'id')::uuid;end if;
  end loop;
  update external_payment_receipts as ep set amount_cents=after_cents,rental_amount_cents=new_rent,credit_amount_cents=new_credit,
   request=ep.request||jsonb_build_object('amountCents',after_cents,'rentalAmountCents',new_rent,'creditAmountCents',new_credit),
   result=ep.result||jsonb_build_object('amountCents',after_cents,'rentalAmountCents',new_rent,'creditAmountCents',new_credit) where id=r.id;
  perform admin_correct_flexible_payment(r.id,method,(p_request->>'receivedDate')::date,nullif(p_request->>'receivedTime','')::time,p_request->>'reference',p_request->>'notes',p_request->>'reason');
 else
  perform admin_correct_legacy_external_payment(p_source_type,p_source_id,(p_request->>'receivedDate')::date,nullif(p_request->>'receivedTime','')::time,p_request->>'reference',p_request->>'notes',p_request->>'reason');
  if original_total is not null then
   created_receipt:=gen_random_uuid();
   insert into external_payment_receipts(id,rental_id,actor_id,request,amount_cents,rental_amount_cents,payment_method,received_date,received_time,reference,notes,status,allocation_version,funding_kind,credit_amount_cents,posted_at,result)
   values(created_receipt,rid,auth.uid(),jsonb_build_object('version',2,'kind','rental_payment','funding','external','amountCents',after_cents,'rentalAmountCents',0,'creditAmountCents',new_credit,'charges',jsonb_build_array(jsonb_build_object('id',p_source_id,'amountCents',least(after_cents,original_total)))) ,after_cents,0,method,(p_request->>'receivedDate')::date,nullif(p_request->>'receivedTime','')::time,p_request->>'reference',p_request->>'notes','posted',2,'external',new_credit,(source->>'paid_at')::timestamptz,jsonb_build_object('status','posted','amountCents',after_cents,'creditAmountCents',new_credit));
   insert into external_payment_allocations(receipt_id,charge_id,amount_cents,snapshot) values(created_receipt,p_source_id,least(after_cents,original_total),source);
   update rental_charge_items set allocation_managed=true,allocated_payment_cents=least(after_cents,original_total),payment_amount_cents=least(after_cents,original_total),external_payment_method=method,
    status=case when after_cents>=original_total then 'paid' else 'pending' end where id=p_source_id;
  else
   execute format('update %I set payment_amount_cents=$1,external_payment_method=$2 where id=$3',tbl) using after_cents,method,p_source_id;
   if p_source_type='rental_charge' then update rental_charge_items set amount=after_cents/100.0,total_amount=after_cents/100.0 where id=p_source_id;end if;
  end if;
 end if;
 perform sync_rental_remaining_balance(rid,auth.uid());
 result:=result||jsonb_build_object('status','corrected','receiptId',created_receipt);
 insert into payment_amount_corrections values(p_key,rid,auth.uid(),p_source_type,p_source_id,p_request,snapshot,result,now());
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(rid,auth.uid(),'payment_amount_corrected',jsonb_build_object('correctionId',p_key,'sourceType',p_source_type,'sourceId',p_source_id,'beforeCents',before_cents,'afterCents',after_cents,'reason',p_request->>'reason','allocations',plan,'creditCents',new_credit));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
 return result;
end $$;
revoke all on function public.admin_correct_payment_amount(text,uuid,jsonb,uuid,text) from public,anon;
grant execute on function public.admin_correct_payment_amount(text,uuid,jsonb,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
