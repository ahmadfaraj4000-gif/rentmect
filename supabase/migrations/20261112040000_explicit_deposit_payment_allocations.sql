begin;
set local lock_timeout='5s';
-- rental_amount_cents remains the combined booking allocation for legacy ledger
-- readers. deposit_amount_cents identifies its refundable portion explicitly.
alter table public.external_payment_receipts add column deposit_amount_cents integer not null default 0
 check(deposit_amount_cents>=0 and deposit_amount_cents<=rental_amount_cents);

create function public.rentmect_payment_due_parts(p_rental_id uuid) returns jsonb
language plpgsql stable security invoker set search_path=public as $$
declare r rentals%rowtype; total integer; funded integer; deposit_due integer;
begin
 select * into strict r from rentals where id=p_rental_id;
 total:=round(greatest(0,rentmect_rental_invoice_total(r.id)-rentmect_rental_net_paid_amount(r.id))*100)::integer;
 select round(coalesce(sum(amount_held-external_receipt_refunded_amount),0)*100)::integer into funded
 from rental_deposit_allocations where holder_rental_id=r.id;
 if not exists(select 1 from rental_deposit_allocations where holder_rental_id=r.id)
   and r.deposit_status in ('held','adjustment_refund_due','release_pending','released','transferred','waived') then
  funded:=round(coalesce(r.security_deposit,0)*100)::integer;
 end if;
 deposit_due:=case when r.status in ('completed','cancelled') or r.deposit_status in ('released','transferred','waived') then 0
 else least(total,greatest(0,round(coalesce(r.security_deposit,0)*100)::integer-funded)) end;
 return jsonb_build_object('rentalDueCents',total-deposit_due,'depositDueCents',deposit_due,'bookingDueCents',total);
end $$;
revoke all on function public.rentmect_payment_due_parts(uuid) from public,anon;
grant execute on function public.rentmect_payment_due_parts(uuid) to authenticated,service_role;

do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.service_prepare_external_payment(uuid,uuid,uuid,jsonb)'::regprocedure) into d;
 d:=replace(d,'rent_cents integer; due integer;', 'deposit_cents integer:=0; parts jsonb; rent_cents integer; due integer;');
 marker:='rent_cents:=(p_request->>''rentalAmountCents'')::integer;';
 if position(marker in d)=0 then raise exception 'Review payment prepare contract.'; end if;
 d:=replace(d,marker,$patch$
 deposit_cents:=coalesce((p_request->>'depositAmountCents')::integer,0);
 if deposit_cents<0 then raise exception 'Invalid deposit allocation.'; end if;
 if deposit_cents>0 and funding='credit' then raise exception 'Collect deposits using Stripe or an external payment.'; end if;
 rent_cents:=(p_request->>'rentalAmountCents')::integer;
 if rent_cents<0 then raise exception 'Invalid rental allocation.'; end if;
 rent_cents:=rent_cents+deposit_cents;$patch$);
 marker:='due:=round(greatest(0,rentmect_rental_invoice_total(r.id)-rentmect_rental_net_paid_amount(r.id))*100)::integer;';
 if position(marker in d)=0 then raise exception 'Review payment balance contract.'; end if;
 d:=replace(d,marker,marker||$patch$
 if p_request ? 'depositAmountCents' then
  parts:=rentmect_payment_due_parts(r.id);
  if deposit_cents>(parts->>'depositDueCents')::integer
    or rent_cents-deposit_cents>(parts->>'rentalDueCents')::integer
    or (deposit_cents>0 and (p_request->>'expectedDepositDueCents')::integer is distinct from (parts->>'depositDueCents')::integer)
    or (rent_cents>deposit_cents and (p_request->>'expectedRentalDueCents')::integer is distinct from (parts->>'rentalDueCents')::integer) then
   raise exception 'Rental or deposit balance changed. Review the payment again.';
  end if;
 end if;
$patch$);
 d:=replace(d,'(rent_cents>0 and (p_request->>''expectedRentalDueCents'')::integer is distinct from due)',
 '(rent_cents>0 and not (p_request ? ''depositAmountCents'') and (p_request->>''expectedRentalDueCents'')::integer is distinct from due)');
 d:=replace(d,'allocation_version,funding_kind,credit_amount_cents)', 'allocation_version,funding_kind,credit_amount_cents,deposit_amount_cents)');
 d:=replace(d,',2,funding,credit_cents);',',2,funding,credit_cents,deposit_cents);');
 execute d;

 select pg_get_functiondef('public.ensure_rental_deposit_allocation(uuid)'::regprocedure) into d;
 d:=replace(d,'begin', $patch$begin
  if current_setting('rentmect.explicit_deposit_receipt',true)='on' then return; end if;
$patch$); -- This function has no nested BEGIN blocks.
 -- An explicit external contribution must never be relabelled as a later Stripe capture.
 d:=replace(d,$m$and nullif(trim(coalesce(stripe_payment_intent_id, '')), '') is null;$m$, $m$and nullif(trim(coalesce(stripe_payment_intent_id, '')), '') is null and flex_payment_receipt_id is null;$m$);
 execute d;

 select pg_get_functiondef('public.service_finish_external_payment(uuid,uuid,boolean)'::regprocedure) into d;
 marker:='if receipt.rental_amount_cents>0 then';
 if position(marker in d)=0 then raise exception 'Review payment posting contract.'; end if;
 d:=replace(d,marker,$patch$
 if receipt.request ? 'depositAmountCents' then
  perform set_config('rentmect.explicit_deposit_receipt','on',true);
 end if;
 if receipt.rental_amount_cents>0 then$patch$);
 marker:='if coalesce((select sum(amount_cents) from external_payment_allocations where receipt_id=p_id),0)+receipt.credit_amount_cents<>receipt.amount_cents then';
 if position(marker in d)=0 then raise exception 'Review payment sum contract.'; end if;
 d:=replace(d,marker,$patch$
 if receipt.request ? 'depositAmountCents' then
  if receipt.deposit_amount_cents>0 then
   insert into rental_deposit_allocations(holder_rental_id,source_rental_id,source_kind,payment_provider,stripe_payment_intent_id,amount_held,flex_payment_receipt_id)
   values(receipt.rental_id,receipt.rental_id,case when receipt.funding_kind='stripe' then 'initial_rental' else 'local_payment' end,case when receipt.funding_kind='stripe' then 'stripe' else 'local' end,
    case when receipt.funding_kind='stripe' then receipt.stripe_payment_intent_id else null end,receipt.deposit_amount_cents/100.0,receipt.id);
  end if;
  perform refresh_rental_deposit_summary(receipt.rental_id);
  perform set_config('rentmect.explicit_deposit_receipt','',true);
 end if;
$patch$||marker);
 d:=replace(d,'''rentalAmountCents'',receipt.rental_amount_cents,', '''rentalAmountCents'',receipt.rental_amount_cents-receipt.deposit_amount_cents,''depositAmountCents'',receipt.deposit_amount_cents,');
 execute d;

 select pg_get_functiondef('public.admin_correct_payment_amount(text,uuid,jsonb,uuid,text)'::regprocedure) into d;
 d:=replace(d,'''rentalAmountCents'',new_rent,''creditAmountCents'',new_credit',
  '''rentalAmountCents'',new_rent-r.deposit_amount_cents,''creditAmountCents'',new_credit');
 execute d;

 select pg_get_functiondef('public.admin_flexible_payment_state(uuid)'::regprocedure) into d;
 d:=replace(d,'''version'',2,', '''version'',2,''depositAllocationsEnabled'',true,''dueParts'',rentmect_payment_due_parts(p_rental_id),');
 execute d;

 -- Explicit receipts refund only their own deposit contribution, never a
 -- different receipt's deposit inferred from the remaining rental balance.
 select pg_get_functiondef('public.admin_adjust_external_rental_payment(uuid,uuid,text,text,text,text)'::regprocedure) into d;
 marker:='v_deposit_returned := greatest(0, round(v_deposit_before - v_deposit_after, 2));';
 if position(marker in d)=0 then raise exception 'Review external refund classification.'; end if;
 d:=replace(d,marker,marker||$patch$
    if exists(select 1 from external_payment_receipts where id=v_charge.flex_payment_receipt_id and request ? 'depositAmountCents') then
      select deposit_amount_cents/100.0 into v_deposit_returned from external_payment_receipts where id=v_charge.flex_payment_receipt_id;
    end if;
$patch$);
 marker:='and payment_provider = ''local''
        and status in (''held'', ''refund_due_inspection'', ''failed'')';
 if position(marker in d)=0 then raise exception 'Review external refund source selection.'; end if;
 d:=replace(d,marker,marker||$patch$
        and (case when exists(select 1 from external_payment_receipts where id=v_charge.flex_payment_receipt_id and request ? 'depositAmountCents')
          then flex_payment_receipt_id=v_charge.flex_payment_receipt_id
          else not exists(select 1 from external_payment_receipts where id=rental_deposit_allocations.flex_payment_receipt_id and request ? 'depositAmountCents') end)
$patch$);
 execute d;

 select pg_get_functiondef('public.flexible_receipt_refund_block_reason(uuid)'::regprocedure) into d;
 marker:='select coalesce(sum(a.amount_cents),0) into rental_cents';
 if position(marker in d)=0 then raise exception 'Review receipt refund protection.'; end if;
 d:=replace(d,marker,$patch$
 if r.request ? 'depositAmountCents' then
  if exists(select 1 from rental_deposit_allocations where flex_payment_receipt_id=r.id and
    (amount_released>0 or amount_applied>0 or holder_rental_id<>r.rental_id or refund_id is not null or refund_reserved_amount is not null or status='release_pending')) then
   return 'This receipt deposit was used, returned, transferred, or reserved. Reconcile the deposit before refunding the full receipt.';
  end if;
  return null;
 end if;
$patch$||marker);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
