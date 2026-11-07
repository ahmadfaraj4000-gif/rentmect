begin;
set local lock_timeout='5s';
set local statement_timeout='30s';

create or replace function public.rentmect_manual_discount_period_basis(p_rental_id uuid,p_discount numeric,p_tax_savings numeric)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare current_periods jsonb; basis jsonb; discounted jsonb; a record; previous_amount numeric:=0;
 old_periods jsonb; new_periods jsonb; restored jsonb; latest_id uuid; correction jsonb; rtotal numeric; ttotal numeric; r public.rentals%rowtype; current_r numeric; current_t numeric;
begin
 select * into strict r from public.rentals where id=p_rental_id;
 current_periods:=public.rentmect_pricing_snapshot(p_rental_id);
 select coalesce(sum((value->>'rental_amount')::numeric),0),coalesce(sum((value->>'tax_amount')::numeric),0)
 into current_r,current_t from jsonb_array_elements(current_periods);
 if current_r is distinct from r.rental_total or current_t is distinct from r.tax_amount then
  raise exception 'Saved pricing periods do not match the rental total. Review the pricing history before changing this discount.';
 end if;
 if p_discount is distinct from r.manual_discount_amount or p_tax_savings is distinct from r.manual_discount_tax_savings then
  raise exception 'Discount changed. Refresh the rental and review the new total.';
 end if;
 if coalesce(p_discount,0)=0 then return current_periods; end if;
 select m.id into latest_id from public.rental_amendments m where m.rental_id=p_rental_id
  and exists(select 1 from public.rental_audit_events e where e.rental_id=p_rental_id
   and e.event_type in ('admin_manual_discount_applied','admin_manual_discount_removed')
   and e.event_payload->>'amendment_id'=m.id::text) order by m.created_at desc,m.id desc limit 1;
 select e.event_payload into correction from public.rental_audit_events e
  where e.rental_id=p_rental_id and e.event_type='manual_discount_basis_reconciled'
   and e.event_payload->>'discount_amendment_id'=latest_id::text
   and (e.event_payload->>'discount_amount')::numeric=p_discount
  order by e.created_at desc,e.id desc limit 1;
 if correction is not null then
  basis:=correction->'discount_period_basis'; discounted:=correction->'discounted_periods'; previous_amount:=p_discount;
 end if;
 if correction is null then
 -- Legacy amendments already retain before/after pricing snapshots. Replay
 -- only discount actions; do not infer discounts from rates or payment labels.
 for a in select m.* from public.rental_amendments m where m.rental_id=p_rental_id
  and exists(select 1 from public.rental_audit_events e where e.rental_id=p_rental_id
   and e.event_type in ('admin_manual_discount_applied','admin_manual_discount_removed')
   and e.event_payload->>'amendment_id'=m.id::text) order by m.created_at,m.id loop
  latest_id:=a.id;
  old_periods:=a.old_values->'pricing_periods'; new_periods:=a.new_values->'pricing_periods';
  if coalesce((a.new_values->>'manual_discount_amount')::numeric,0)=0 then
   basis:=null; discounted:=null; previous_amount:=0; continue;
  end if;
  if jsonb_typeof(old_periods)='array' and jsonb_typeof(new_periods)='array' then
   if (select sum((value->>'rental_amount')::numeric) from jsonb_array_elements(old_periods)) is distinct from (a.old_values->>'rental_total')::numeric
    or (select sum((value->>'tax_amount')::numeric) from jsonb_array_elements(old_periods)) is distinct from (a.old_values->>'tax_amount')::numeric
    or (select sum((value->>'rental_amount')::numeric) from jsonb_array_elements(new_periods)) is distinct from (a.new_values->>'rental_total')::numeric
    or (select sum((value->>'tax_amount')::numeric) from jsonb_array_elements(new_periods)) is distinct from (a.new_values->>'tax_amount')::numeric then
    raise exception 'Discount amendment totals do not match their saved pricing periods. Review the pricing history.';
   end if;
  end if;
  if a.new_values ? 'discount_period_basis' then basis:=a.new_values->'discount_period_basis';
  elsif coalesce((a.old_values->>'manual_discount_amount')::numeric,0)=0 then basis:=old_periods;
  elsif basis is not null and previous_amount=(a.old_values->>'manual_discount_amount')::numeric then
   basis:=public.rentmect_project_discount_basis(old_periods,basis,discounted);
  else
   basis:=null;
  end if;
  discounted:=new_periods;
  previous_amount:=(a.new_values->>'manual_discount_amount')::numeric;
 end loop;
 end if;
 if basis is null or previous_amount<>p_discount then
  -- One period is unambiguous even for a pre-ledger legacy booking.
  if jsonb_array_length(current_periods)=1 then
   return jsonb_build_array((current_periods->0)||jsonb_build_object(
    'rental_amount',(current_periods->0->>'rental_amount')::numeric+p_discount,
    'tax_amount',(current_periods->0->>'tax_amount')::numeric+coalesce(p_tax_savings,0)));
  end if;
  raise exception 'The original discount allocation could not be verified. Review the saved pricing before changing it.';
 end if;
 restored:=public.rentmect_project_discount_basis(current_periods,basis,discounted);
 select sum((value->>'rental_amount')::numeric),sum((value->>'tax_amount')::numeric) into rtotal,ttotal from jsonb_array_elements(restored);
 select rtotal-sum((value->>'rental_amount')::numeric),ttotal-sum((value->>'tax_amount')::numeric) into rtotal,ttotal from jsonb_array_elements(current_periods);
 -- Allocation tax is historical; the display field is a whole-invoice tax
 -- difference. Extensions can change the latter by a cent without changing
 -- any historical discount. Accept only the exact snapshot-trigger identity;
 -- never loosen the rental allocation or substitute a numerical tolerance.
 if rtotal is distinct from p_discount or (ttotal is distinct from coalesce(p_tax_savings,0) and not coalesce((
   r.pre_manual_discount_rental_total = current_r+p_discount
   and r.pre_manual_discount_tax_amount = round((current_r+p_discount+coalesce(r.taxable_service_fee_total,0))*0.0635,2)
   and p_tax_savings = greatest(0,r.pre_manual_discount_tax_amount-current_t)
 ),false)) then
  raise exception 'Saved discount allocations do not match the rental discount. Review before repricing.';
 end if;
 return restored;
end $$;

-- Preview and save share the same historical validation. Apply calls preview
-- again after locking the rental, and the dated trigger also revalidates it.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.admin_preview_manual_rental_discount(uuid,text,numeric)'::regprocedure) into definition;
 if position('perform public.rentmect_manual_discount_period_basis' in definition)>0 then return; end if;
 marker := '  v_service_fees := round(coalesce(v_rental.service_fee_total, 0), 2);';
 if position(marker in definition)=0 then raise exception 'Review discount preview before upgrading.'; end if;
 definition:=replace(definition,marker,$patch$
  perform public.rentmect_manual_discount_period_basis(v_rental.id,
    v_rental.manual_discount_amount,v_rental.manual_discount_tax_savings);
$patch$||marker);
 marker := '  return jsonb_build_object(';
 if position(marker in definition)=0 then raise exception 'Review discount preview response before upgrading.'; end if;
 definition:=replace(definition,marker,$patch$
  if v_new_total>v_old_total+0.005 and v_paid>=v_old_total-0.005 and v_paid>0 then
    raise exception 'A paid rental discount cannot be reduced or removed until its customer credit is settled.';
  end if;
$patch$||marker);
 execute definition;
end $$;
notify pgrst,'reload schema';
commit;
