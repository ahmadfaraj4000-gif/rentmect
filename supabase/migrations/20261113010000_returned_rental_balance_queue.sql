begin;
set local lock_timeout='5s';
-- The list is security-invoker. Keep private accounting helpers private and
-- expose only a checked balance reader for staff who can view rentals.
create function public.rentmect_returned_balance_due(p_rental_id uuid) returns numeric
language plpgsql stable security definer set search_path=public as $$
begin
 if coalesce(auth.role(),'')<>'service_role' and (auth.uid() is null or not coalesce(is_admin(),false)
   or not coalesce(rentmect_has_permission('tab.rentals'),false)) then
  raise exception 'Rental access required.';
 end if;
 if not exists(select 1 from rentals where id=p_rental_id and status='completed') then return 0; end if;
 return greatest(0,rentmect_rental_invoice_total(p_rental_id)-rentmect_rental_net_paid_amount(p_rental_id))
  +coalesce((select sum(rentmect_charge_remaining_amount(c)) from rental_charge_items c
    where c.rental_id=p_rental_id and not c.included_in_initial_payment
      and c.charge_type not in ('rental_amendment','rental_installment')),0);
end $$;
revoke all on function public.rentmect_returned_balance_due(uuid) from public,anon;
grant execute on function public.rentmect_returned_balance_due(uuid) to authenticated,service_role;
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) into d;
 marker:='public.rentmect_needs_deposit_review(r) as deposit_review,';
 if position(marker in d)=0 or position('''needs_action'',not terminal and' in d)=0 then
  raise exception 'Review rental list classification contract.';
 end if;
 d:=replace(d,marker,$patch$
 case when r.status='completed' then public.rentmect_returned_balance_due(r.id) else 0 end as returned_balance_due,
 $patch$||marker);
 d:=replace(d,'''archive'',terminal and not deposit_review,','''archive'',terminal and not deposit_review and returned_balance_due<=0.005,');
 d:=replace(d,'''needs_action'',not terminal and','''needs_action'',returned_balance_due>0.005 or not terminal and');
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
