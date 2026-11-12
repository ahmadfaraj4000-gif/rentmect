begin;
set local lock_timeout='5s';
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) into d;
 marker:='public.rentmect_needs_deposit_review(r) as deposit_review,';
 if position(marker in d)=0 or position('''needs_action'',not terminal and' in d)=0 then
  raise exception 'Review rental list classification contract.';
 end if;
 d:=replace(d,marker,$patch$
 case when r.status='completed' then
  greatest(0,public.rentmect_rental_invoice_total(r.id)-public.rentmect_rental_net_paid_amount(r.id))
  +coalesce((select sum(public.rentmect_charge_remaining_amount(c)) from public.rental_charge_items c
    where c.rental_id=r.id and not c.included_in_initial_payment and c.charge_type not in ('rental_amendment','rental_installment')),0)
  else 0 end as returned_balance_due,
 $patch$||marker);
 d:=replace(d,'''archive'',terminal and not deposit_review,','''archive'',terminal and not deposit_review and returned_balance_due<=0.005,');
 d:=replace(d,'''needs_action'',not terminal and','''needs_action'',returned_balance_due>0.005 or not terminal and');
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
