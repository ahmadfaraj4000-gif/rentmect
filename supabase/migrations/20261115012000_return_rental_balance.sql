begin;
set local lock_timeout='5s';
-- Include the existing invoice-balance representation, never installment attempts.
do $$ declare d text; begin
 select pg_get_functiondef('public.admin_return_workspace(uuid)'::regprocedure) into d;
 if position($m$c.charge_type not in ('rental_amendment','rental_installment')$m$ in d)=0 then raise exception 'Workspace contract changed'; end if;
 d:=replace(d,$m$c.charge_type not in ('rental_amendment','rental_installment')$m$,$m$c.charge_type<>'rental_installment' and (c.charge_type<>'rental_amendment' or c.source_type in ('rental_balance','rental_amendment'))$m$);
 execute d;
 select pg_get_functiondef('public.service_apply_deposit_review(uuid,uuid,uuid,jsonb,jsonb,jsonb)'::regprocedure) into d;
 if position($m$c.charge_type in ('rental_amendment','rental_installment')$m$ in d)=0 then raise exception 'Settlement contract changed'; end if;
 d:=replace(d,$m$c.charge_type in ('rental_amendment','rental_installment')$m$,$m$c.charge_type='rental_installment'$m$);
 d:=replace(d,'budget:=least(held,selected_total);',$guard$
 -- Rental debt is part of the invoice, not an extra fee. Validate its exact
 -- remainder under the rental lock and settle it first to avoid double-counting.
 if exists(select 1 from rental_charge_items where id=any(ids) and charge_type='rental_amendment') then
  perform require_external_payment_actor(p_actor_id,'payment.collect');
  if (select count(*) from rental_charge_items where id=any(ids) and charge_type='rental_amendment')<>1
   or exists(select 1 from rental_charge_items debt where id=any(ids) and charge_type='rental_amendment'
     and (coalesce(source_type,'') not in ('rental_balance','rental_amendment') or rentmect_charge_remaining_amount(debt)<>
       greatest(0,rentmect_rental_invoice_total(r.id)-rentmect_rental_net_paid_amount(r.id)))) then
   raise exception 'Rental balance changed. Reload the return review.';
  end if;
  if r.paid_at is null and (r.stripe_checkout_session_id is not null or r.stripe_payment_intent_id is not null)
   or exists(select 1 from rental_charge_items where rental_id=r.id and charge_type in ('rental_amendment','rental_installment')
     and status in ('pending','failed','checkout_open') and not(id=any(ids))) then
   raise exception 'Resolve other rental payment attempts before deducting the rental balance.';
  end if;
  if held+credit_total/100.0 < (select rentmect_charge_remaining_amount(debt) from rental_charge_items debt where id=any(ids) and charge_type='rental_amendment') then
   raise exception 'Deposit and selected credit do not cover the rental balance. Collect the shortfall before settling it.';
  end if;
 end if;
 budget:=least(held,selected_total);$guard$);
 d:=replace(d,'where id=any(ids) order by id','where id=any(ids) order by (charge_type=''rental_amendment'') desc,id');
 d:=replace(d,'perform refresh_rental_deposit_summary(r.id);',$sync$
 if exists(select 1 from rental_charge_items where id=any(ids) and charge_type='rental_amendment') then
  perform sync_rental_remaining_balance(r.id,p_actor_id);
 end if;
 perform refresh_rental_deposit_summary(r.id);$sync$);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
