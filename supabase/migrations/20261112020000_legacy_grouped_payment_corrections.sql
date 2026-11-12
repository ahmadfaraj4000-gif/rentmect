begin;
set local lock_timeout='5s';
-- Older posted receipts are upgraded only inside a confirmed correction, never by a preview.
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.admin_correct_payment_amount(text,uuid,jsonb,uuid,text)'::regprocedure) into d;
 if position('or r.allocation_version<>2' in d)=0 then raise exception 'Review changed payment correction contract.';end if;
 d:=replace(d,'or r.allocation_version<>2','or r.allocation_version not in (1,2)');
 marker:=$marker$ if p_source_type='receipt' then
  for entry in select value from jsonb_array_elements(plan) loop$marker$;
 if position(marker in d)=0 then raise exception 'Review correction commit section before upgrading legacy receipts.';end if;
 d:=replace(d,marker,$patch$ if p_source_type='receipt' then
  if r.allocation_version=1 then
   if (select coalesce(sum(amount_cents),0) from external_payment_allocations where receipt_id=r.id)<>r.amount_cents
    or exists(select 1 from external_payment_allocations allocation join rental_charge_items c on c.id=allocation.charge_id where allocation.receipt_id=r.id and
     (c.payment_receipt_id is distinct from r.id or c.rental_id<>rid or c.status<>'paid' or c.payment_provider is distinct from 'local' or
      c.external_refunded_amount>0 or c.allocation_managed or c.flex_payment_receipt_id is not null or coalesce(c.payment_amount_cents,round(c.total_amount*100)::integer)<>allocation.amount_cents)) then
    raise exception 'The original receipt needs reconciliation before its amount can be corrected.';
   end if;
   update rental_charge_items c set payment_receipt_id=null,
    flex_payment_receipt_id=case when c.charge_type='rental_amendment' then r.id else null end,
    allocation_managed=c.charge_type<>'rental_amendment',
    allocated_payment_cents=case when c.charge_type='rental_amendment' then 0 else allocation.amount_cents end
    from external_payment_allocations allocation where allocation.receipt_id=r.id and allocation.charge_id=c.id;
   update external_payment_receipts set allocation_version=2,request=request||jsonb_build_object('version',2,'funding','external') where id=r.id;
  end if;
  for entry in select value from jsonb_array_elements(plan) loop$patch$);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
