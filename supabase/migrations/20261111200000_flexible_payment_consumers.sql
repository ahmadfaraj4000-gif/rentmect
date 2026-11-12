begin;
set local lock_timeout='5s';
-- Preserve all existing authentication, pricing and deposit guards. Only the
-- outstanding-charge expression changes; source-shape checks fail closed.
do $$ declare definition text; signature text; begin
 foreach signature in array array['public.get_rental_account(uuid)','public.rentmect_unpaid_charge_total(uuid)',
 'public.service_deduct_deposit_charges(uuid,uuid,uuid[],numeric,numeric,jsonb,jsonb,uuid,text,uuid)',
 'public.service_apply_deposit_to_charges(uuid,uuid[],numeric,numeric,uuid,text)'] loop
  select pg_get_functiondef(signature::regprocedure) into definition;
  if position('sum(total_amount)' in definition)=0 then raise exception 'Review changed outstanding charge calculation: %',signature; end if;
  definition:=replace(definition,'sum(total_amount)','sum(public.rentmect_charge_remaining_amount(rental_charge_items))');
  if signature like 'public.service_%' then
   if position('c.total_amount' in definition)=0 then raise exception 'Review changed deposit application: %',signature; end if;
   definition:=replace(definition,'c.total_amount','public.rentmect_charge_remaining_amount(c)');
  end if;
  if signature='public.get_rental_account(uuid)' then
   if position('''credit_due'',greatest(0,paid-invoice)' in definition)=0 then raise exception 'Review changed account credit fields.'; end if;
   definition:=replace(definition,'''credit_due'',greatest(0,paid-invoice)',
    '''credit_due'',greatest(0,paid-invoice),''available_customer_credit'',public.rental_available_credit_cents(r.id)/100.0');
  end if;
  execute definition;
 end loop;
end $$;

-- Mixed funding keeps the original deposit application immutable while an
-- audited receipt operation changes only the non-deposit allocation.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.protect_deposit_settlement()'::regprocedure) into definition;
 marker:='   if new.status<>''paid'' or new.payment_provider is distinct from ''deposit'' or';
 if position(marker in definition)=0 then raise exception 'Review changed deposit settlement protection.'; end if;
 definition:=replace(definition,marker,$guard$
   if old.allocation_managed and new.allocated_deposit_cents=old.allocated_deposit_cents
     and new.allocated_deposit_cents=(select coalesce(sum(round(amount*100)),0) from rental_deposit_charge_applications where charge_id=old.id)
     and new.payment_provider='deposit'
     and (to_jsonb(new)-array['allocated_payment_cents','allocated_waiver_cents','status','payment_amount_cents','paid_at','updated_at','last_admin_charge_error'])
       is not distinct from (to_jsonb(old)-array['allocated_payment_cents','allocated_waiver_cents','status','payment_amount_cents','paid_at','updated_at','last_admin_charge_error'])
     and (current_setting('rentmect.external_payment_write',true)='on'
       or (old.status in ('pending','failed') and new.status='waived' and new.allocated_payment_cents=old.allocated_payment_cents
         and new.allocated_waiver_cents=round(old.total_amount*100)-old.allocated_payment_cents-old.allocated_deposit_cents)) then
    return new;
   end if;
   if new.status<>'paid' or new.payment_provider is distinct from 'deposit' or$guard$);
 execute definition;
end $$;

do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.check_deposit_application_total()'::regprocedure) into definition;
 marker:='c.status<>''paid'' or c.payment_provider is distinct from ''deposit'' or c.total_amount<>d.amount';
 if position(marker in definition)=0 then raise exception 'Review changed deposit application constraint.'; end if;
 execute replace(definition,marker,$check$case when c.allocation_managed then
   c.payment_provider is distinct from 'deposit' or c.status not in ('paid','pending','waived') or
   c.allocated_deposit_cents<>(select coalesce(sum(round(amount*100)),0) from public.rental_deposit_charge_applications where charge_id=c.id)
   else c.status<>'paid' or c.payment_provider is distinct from 'deposit' or c.total_amount<>d.amount end$check$);
end $$;

create function public.admin_flexible_payment_revenue() returns jsonb
language plpgsql stable security invoker set search_path=public as $$
begin
 if auth.uid() is null or not is_admin() or not coalesce(rentmect_has_permission('reports.financial'),false)
 or not coalesce(rentmect_has_permission('tab.payments'),false)
 or not exists(select 1 from profiles where id=auth.uid() and lower(email)='anconamgt@aol.com') then raise exception 'Revenue report access denied.'; end if;
 return jsonb_build_object('allocatedReceipts',coalesce((select jsonb_agg(jsonb_build_object(
  'id',id,'rental_id',rental_id,'funding_kind',funding_kind,'amount_cents',amount_cents,'credit_amount_cents',credit_amount_cents,
  'status',status,'received_date',received_date,'posted_at',posted_at,'refunded_at',refunded_at)) from external_payment_receipts where allocation_version=2 and status in ('posted','refunded')),'[]'),
  'allocatedEntries',coalesce((select jsonb_agg(jsonb_build_object('receipt_id',a.receipt_id,'charge_id',a.charge_id,'amount_cents',a.amount_cents,
  'charge_type',a.snapshot->>'charge_type','total_amount',a.snapshot->'total_amount','tax_amount',a.snapshot->'tax_amount'))
  from external_payment_allocations a join external_payment_receipts r on r.id=a.receipt_id where r.allocation_version=2 and r.status in ('posted','refunded')),'[]'));
end $$;
revoke all on function public.admin_flexible_payment_revenue() from public,anon;
grant execute on function public.admin_flexible_payment_revenue() to authenticated;

create function public.admin_correct_flexible_payment(p_receipt_id uuid,p_method text,p_received_date date,p_received_time time,p_reference text,p_notes text,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare receipt external_payment_receipts%rowtype; prior text;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('payment.collect'),false) then raise exception 'Payment correction permission required.'; end if;
 if length(trim(coalesce(p_reason,'')))<5 then raise exception 'Provide a correction reason.'; end if;
 if p_method is null or p_method not in ('cash','cash_app','terminal','card','bank_transfer','other') then raise exception 'Choose an external payment method.'; end if;
 if p_received_date is null or p_received_date>(now() at time zone 'America/New_York')::date or
 (p_received_time is not null and p_received_date+p_received_time>(now() at time zone 'America/New_York')) then raise exception 'Choose a received time no later than now.'; end if;
 if length(coalesce(p_reference,''))>120 or length(coalesce(p_notes,''))>2000 then raise exception 'Payment details are too long.'; end if;
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=p_receipt_id) for update;
 select * into strict receipt from external_payment_receipts where id=p_receipt_id for update;
 if receipt.status<>'posted' or receipt.allocation_version<>2 or receipt.funding_kind<>'external' then raise exception 'Only a posted external receipt can be corrected.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=receipt.rental_id and status='pending') then raise exception 'Resolve the pending payment first.'; end if;
 prior:=current_setting('rentmect.external_payment_write',true); perform set_config('rentmect.external_payment_write','on',true);
 update external_payment_receipts set payment_method=p_method,received_date=p_received_date,received_time=p_received_time,reference=nullif(trim(p_reference),''),notes=nullif(trim(p_notes),'') where id=p_receipt_id;
 update rental_charge_items set external_payment_method=p_method,payment_received_date=p_received_date,payment_received_time=p_received_time,external_payment_reference=nullif(trim(p_reference),'') where flex_payment_receipt_id=p_receipt_id;
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(receipt.rental_id,auth.uid(),'flexible_payment_corrected',jsonb_build_object('before',to_jsonb(receipt),'method',p_method,'received_date',p_received_date,'received_time',p_received_time,'reference',p_reference,'notes',p_notes,'reason',p_reason));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
end $$;
revoke all on function public.admin_correct_flexible_payment(uuid,text,date,time,text,text,text) from public,anon;
grant execute on function public.admin_correct_flexible_payment(uuid,text,date,time,text,text,text) to authenticated;
-- Narrow cash activity reader: no private request snapshots or staff notes.
create function public.admin_flexible_payment_activity() returns jsonb
language plpgsql stable security invoker set search_path=public as $$
begin
 if auth.uid() is null or not is_admin() or not coalesce(rentmect_has_permission('tab.payments'),false) then raise exception 'Payment access required.'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'rental_id',rental_id,'funding_kind',funding_kind,
  'amount_cents',amount_cents,'credit_amount_cents',credit_amount_cents,'status',status,'posted_at',posted_at,
  'received_date',received_date,'received_time',received_time,'refunded_at',refunded_at))
  from external_payment_receipts where allocation_version=2 and status in ('posted','refunded')),'[]');
end $$;
revoke all on function public.admin_flexible_payment_activity() from public,anon;
grant execute on function public.admin_flexible_payment_activity() to authenticated;

-- Old metadata clients must use the same audited correction for new receipts.
alter function public.admin_correct_external_payment(uuid,date,time,text,text,text) rename to admin_correct_external_payment_v1;
revoke all on function public.admin_correct_external_payment_v1(uuid,date,time,text,text,text) from public,anon,authenticated;
create function public.admin_correct_external_payment(p_receipt_id uuid,p_received_date date,p_received_time time,p_reference text,p_notes text,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare r external_payment_receipts%rowtype;
begin
 select * into strict r from external_payment_receipts where id=p_receipt_id;
 if r.allocation_version=2 then
  perform admin_correct_flexible_payment(p_receipt_id,r.payment_method,p_received_date,p_received_time,p_reference,p_notes,p_reason);
 else
  perform admin_correct_external_payment_v1(p_receipt_id,p_received_date,p_received_time,p_reference,p_notes,p_reason);
 end if;
end $$;
revoke all on function public.admin_correct_external_payment(uuid,date,time,text,text,text) from public,anon;
grant execute on function public.admin_correct_external_payment(uuid,date,time,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
