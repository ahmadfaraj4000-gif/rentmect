begin;
-- Apply the new rules only to agreements with a captured tax basis.
create function public.ct_extension_pricing(r public.rentals, replacement uuid, kind text,
  until_date date, until_time text) returns table(rate numeric, surcharge_delta numeric)
language plpgsql stable security definer set search_path=public as $$
declare days integer; new_days integer; value numeric;
begin
  rate:=coalesce(r.contract_sales_tax_rate,0.0635);
  surcharge_delta:=0;
  if r.contract_sales_tax_rate is null then return next; return; end if;
  if kind='switch_car_continuation' then
    days:=rentmect_billable_days(r.return_date,r.return_time,until_date,until_time);
    select agreed_vehicle_value into value from vehicles where id=replacement;
    rate:=ct_passenger_rental_rate(days,value);
    if rate is null then raise exception 'Record the replacement vehicle value before quoting this long-term agreement.'; end if;
    surcharge_delta:=ct_tourism_surcharge(days);
  elsif rate=0.0935 then
    new_days:=rentmect_billable_days(r.pickup_date,r.pickup_time,until_date,until_time);
    if new_days>30 then raise exception 'This amendment takes the original short-term agreement past 30 days. The tax treatment requires review before an amount can be quoted.'; end if;
    surcharge_delta:=new_days-r.tourism_surcharge;
  end if;
  return next;
end $$;
revoke all on function public.ct_extension_pricing(public.rentals,uuid,text,date,text) from public,anon,authenticated;
create function public.sync_contract_surcharge() returns trigger language plpgsql security definer set search_path=public as $$
declare delta numeric;
begin
  if old.contract_sales_tax_rate is null then return new; end if;
  select surcharge_delta into delta from ct_extension_pricing(old,old.vehicle_id,'same_vehicle_extension',new.return_date,new.return_time);
  new.tourism_surcharge:=old.tourism_surcharge+delta;
  new.service_fee_total:=coalesce(old.service_fee_total,0)+delta;
  return new;
end $$;
create trigger zzzzz_sync_contract_surcharge before update of return_date,return_time on public.rentals
for each row when ((old.return_date,old.return_time) is distinct from (new.return_date,new.return_time))
execute function public.sync_contract_surcharge();

-- Keep the existing eligibility, receipt, deposit and immutable-quote rules in each operation.
do $$
declare f record; d text; basis text; prefix text; revised text;
begin
 for f in select oid,proname from pg_proc where pronamespace='public'::regnamespace and proname in
 ('rentmect_build_extension_quote_before_periods','admin_preview_extension_rate','rentmect_freeze_extension_quote',
  'decide_admin_rental_extension','admin_preview_rental_extension','admin_preview_rental_extension_revision') loop
  d:=pg_get_functiondef(f.oid);
  case f.proname
  when 'rentmect_build_extension_quote_before_periods' then
    basis:='public.ct_extension_pricing(v_rental,p_vehicle_id,p_request_kind,p_requested_return_date,v_return_time)';
    revised:=replace(d,'public.contract_tax_rate(p_rental_id)','(select rate from '||basis||')');
    revised:=replace(revised,'''extension_total_amount'', v_rental_amount + v_tax + v_increase',
      '''tourism_surcharge'', (select surcharge_delta from '||basis||'), ''extension_total_amount'', v_rental_amount + v_tax + v_increase + (select surcharge_delta from '||basis||')');
  when 'admin_preview_extension_rate' then
    basis:='public.ct_extension_pricing(r,e.replacement_vehicle_id,e.request_kind,e.requested_return_date,e.requested_return_time)';
    revised:=replace(d,'public.contract_tax_rate(r.id)','(select rate from '||basis||')');
    revised:=replace(revised,'amount+tax+deposit_increase','amount+tax+deposit_increase+(select surcharge_delta from '||basis||')');
  when 'rentmect_freeze_extension_quote' then
    basis:='public.ct_extension_pricing(r,new.replacement_vehicle_id,new.request_kind,new.requested_return_date,new.requested_return_time)';
    revised:=replace(d,'public.contract_tax_rate(new.rental_id)','(select rate from '||basis||')');
    revised:=replace(revised,'+coalesce(new.extension_deposit_amount,0);','+coalesce(new.extension_deposit_amount,0)+(select surcharge_delta from '||basis||');');
  when 'decide_admin_rental_extension' then
    basis:='public.ct_extension_pricing(v_rental,v_request.replacement_vehicle_id,v_request.request_kind,v_request.requested_return_date,v_request.requested_return_time)';
    revised:=replace(d,'public.contract_tax_rate(v_rental.id)','(select rate from '||basis||')');
    revised:=replace(revised,'+ v_extension_deposit_amount,','+ v_extension_deposit_amount + (select surcharge_delta from '||basis||'),');
  when 'admin_preview_rental_extension' then
    basis:='public.ct_extension_pricing(r,r.vehicle_id,''same_vehicle_extension'',p_return_date,p_return_time)';
    revised:=replace(d,'amount+tax','amount+tax+(select surcharge_delta from '||basis||')');
    revised:=replace(revised,'''extension_days'',units','''tourism_surcharge'',(select surcharge_delta from '||basis||'),''extension_days'',units');
  when 'admin_preview_rental_extension_revision' then
    basis:='public.ct_extension_pricing(r,r.vehicle_id,''same_vehicle_extension'',p_return_date,p_return_time)';
    revised:=replace(d,'delta:=amount+tax-p.rental_amount-p.tax_amount;', 'delta:=amount+tax-p.rental_amount-p.tax_amount+(select surcharge_delta from '||basis||');');
  end case;
  if revised=d then raise exception 'Review changed extension routine %',f.proname; end if;
  execute revised;
 end loop;
end $$;
commit;
