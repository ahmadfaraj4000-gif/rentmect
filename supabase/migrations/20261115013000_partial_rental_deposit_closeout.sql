begin;
set local lock_timeout='5s';
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.service_apply_deposit_review(uuid,uuid,uuid,jsonb,jsonb,jsonb)'::regprocedure) into d;
 marker:=$old$  if held+credit_total/100.0 < (select rentmect_charge_remaining_amount(debt) from rental_charge_items debt where id=any(ids) and charge_type='rental_amendment') then
   raise exception 'Deposit and selected credit do not cover the rental balance. Collect the shortfall before settling it.';
  end if;$old$;
 if position(marker in d)=0 then raise exception 'Partial closeout contract changed'; end if;
 d:=replace(d,marker,'');
 marker:=$old$perform set_config('rentmect.deposit_review_write','on',true);$old$;
 if position(marker in d)=0 then raise exception 'Settlement write guard changed'; end if;
 d:=replace(d,marker,$new$perform set_config('rentmect.deposit_review_write','on',true);
 -- Split a partially covered invoice into a paid portion and a new remainder.
 -- Snapshot and invoice validation above use the full selected debt. Existing
 -- payment consumers can then collect the new remainder without modifying
 -- the immutable deposit application or counting its funds as new cash.
 for c in select * from rental_charge_items where id=any(ids) and charge_type='rental_amendment' loop
  if held+credit_total/100.0 < rentmect_charge_remaining_amount(c) then
   if held+credit_total/100.0<=0 then raise exception 'No deposit or selected credit is available to apply.'; end if;
   update rental_charge_items set amount=total_amount-rentmect_charge_remaining_amount(c)+held+credit_total/100.0,
    total_amount=total_amount-rentmect_charge_remaining_amount(c)+held+credit_total/100.0,
    description='Rental invoice portion settled from deposit and credit; the unpaid remainder is recorded separately.',
    updated_at=now() where id=c.id;
  end if;
 end loop;$new$);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
