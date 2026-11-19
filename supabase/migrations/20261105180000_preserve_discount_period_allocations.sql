begin;
-- Restore the actual discount assigned to each historical pricing interval.
-- New extension periods receive no part of an earlier booking discount. When
-- a vehicle swap splits a period, cumulative rounding preserves every cent.
create function public.rentmect_project_discount_basis(p_current jsonb,p_basis jsonb,p_discounted jsonb)
returns jsonb language plpgsql immutable set search_path=public as $$
declare c jsonb; d jsonb; b jsonb; result jsonb:='[]'; rd numeric; td numeric;
 extra_r numeric; extra_t numeric; lo timestamptz; hi timestamptz; ds timestamptz; de timestamptz;
 total_seconds numeric; covered numeric;
begin
 if jsonb_typeof(p_current) is distinct from 'array' or jsonb_typeof(p_basis) is distinct from 'array'
  or jsonb_typeof(p_discounted) is distinct from 'array' then raise exception 'Discount period history is incomplete. Review the saved pricing before changing this discount.'; end if;
 for d in select value from jsonb_array_elements(p_discounted) loop
  select value into b from jsonb_array_elements(p_basis) where
   (value->>'starts_at')::timestamptz=(d->>'starts_at')::timestamptz and
   (value->>'ends_at')::timestamptz=(d->>'ends_at')::timestamptz;
  if b is null then raise exception 'Discount period history does not match its original pricing.'; end if;
  rd:=(b->>'rental_amount')::numeric-(d->>'rental_amount')::numeric;
  td:=(b->>'tax_amount')::numeric-(d->>'tax_amount')::numeric;
  if rd=0 and td=0 then continue; end if;
  ds:=(d->>'starts_at')::timestamptz; de:=(d->>'ends_at')::timestamptz;
  select coalesce(sum(greatest(0,extract(epoch from least((value->>'ends_at')::timestamptz,de)-greatest((value->>'starts_at')::timestamptz,ds)))),0)
   into covered from jsonb_array_elements(p_current);
  if de<=ds or covered<>extract(epoch from de-ds) then
   raise exception 'Discounted dates changed. Reconcile the saved discount allocation before repricing.';
  end if;
 end loop;
 for c in select value from jsonb_array_elements(p_current) order by (value->>'starts_at')::timestamptz loop
  extra_r:=0; extra_t:=0;
  for d in select value from jsonb_array_elements(p_discounted) loop
   select value into strict b from jsonb_array_elements(p_basis) where
    (value->>'starts_at')::timestamptz=(d->>'starts_at')::timestamptz and
    (value->>'ends_at')::timestamptz=(d->>'ends_at')::timestamptz;
   ds:=(d->>'starts_at')::timestamptz; de:=(d->>'ends_at')::timestamptz;
   lo:=greatest((c->>'starts_at')::timestamptz,ds); hi:=least((c->>'ends_at')::timestamptz,de);
   if hi<=lo then continue; end if;
   total_seconds:=extract(epoch from de-ds);
   rd:=(b->>'rental_amount')::numeric-(d->>'rental_amount')::numeric;
   td:=(b->>'tax_amount')::numeric-(d->>'tax_amount')::numeric;
   extra_r:=extra_r+round(rd*extract(epoch from hi-ds)/total_seconds,2)-round(rd*extract(epoch from lo-ds)/total_seconds,2);
   extra_t:=extra_t+round(td*extract(epoch from hi-ds)/total_seconds,2)-round(td*extract(epoch from lo-ds)/total_seconds,2);
  end loop;
  if (c->>'rental_amount')::numeric+extra_r<0 or (c->>'tax_amount')::numeric+extra_t<0 then
   raise exception 'Discount allocation would create a negative pricing period.'; end if;
  result:=result||jsonb_build_array(c||jsonb_build_object('rental_amount',(c->>'rental_amount')::numeric+extra_r,
   'tax_amount',(c->>'tax_amount')::numeric+extra_t));
 end loop;
 return result;
end $$;

create function public.rentmect_manual_discount_period_basis(p_rental_id uuid,p_discount numeric,p_tax_savings numeric)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare current_periods jsonb; basis jsonb; discounted jsonb; a record; previous_amount numeric:=0;
 old_periods jsonb; new_periods jsonb; restored jsonb; latest_id uuid; correction jsonb; rtotal numeric; ttotal numeric;
begin
 current_periods:=public.rentmect_pricing_snapshot(p_rental_id);
 if coalesce(p_discount,0)=0 then return current_periods; end if;
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
 select e.event_payload into correction from public.rental_audit_events e
  where e.rental_id=p_rental_id and e.event_type='manual_discount_basis_reconciled'
   and e.event_payload->>'discount_amendment_id'=latest_id::text
   and (e.event_payload->>'discount_amount')::numeric=p_discount
  order by e.created_at desc,e.id desc limit 1;
 if correction is not null then
  basis:=correction->'discount_period_basis'; discounted:=correction->'discounted_periods'; previous_amount:=p_discount;
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
 if rtotal<>p_discount or ttotal<>coalesce(p_tax_savings,0) then
  raise exception 'Saved discount allocations do not match the rental discount. Review before repricing.';
 end if;
 return restored;
end $$;
revoke all on function public.rentmect_project_discount_basis(jsonb,jsonb,jsonb),public.rentmect_manual_discount_period_basis(uuid,numeric,numeric) from public,anon,authenticated;

-- Keep the established authorization guard; replace only its allocation math.
do $$ declare definition text; old_block text; new_block text; begin
 select pg_get_functiondef('public.rentmect_guard_dated_rental()'::regprocedure) into definition;
 old_block:=substring(definition from position('      -- Apply the explicitly requested whole-rental discount' in definition)
  for position('    else'||chr(10)||'      raise exception ''Dated rental pricing' in definition)-position('      -- Apply the explicitly requested whole-rental discount' in definition));
 if old_block is null or position('with weights as (' in old_block)=0 then raise exception 'Review dated discount guard before upgrading.'; end if;
 new_block:=$block$
      -- Save the exact undiscounted basis before changing any current periods.
      update public.rental_amendments set new_values=new_values||jsonb_build_object(
        'discount_period_basis',public.rentmect_manual_discount_period_basis(old.id,old.manual_discount_amount,old.manual_discount_tax_savings))
        where id::text=current_setting('rentmect.manual_discount_amendment',true);
      with basis as (
        select b.value from public.rental_amendments a,
          lateral jsonb_array_elements(a.new_values->'discount_period_basis') b
        where a.id::text=current_setting('rentmect.manual_discount_amendment',true)
      ), weights as (
        select p.id,p.starts_at,(basis.value->>'rental_amount')::numeric as weight,
          (basis.value->>'tax_amount')::numeric as tax_weight
        from public.rental_pricing_periods p join basis
          on (basis.value->>'starts_at')::timestamptz=p.starts_at and (basis.value->>'ends_at')::timestamptz=p.ends_at
        where p.rental_id=old.id
      ), shares as (
        select *,sum(weight) over(order by starts_at,id) cumulative,sum(weight) over() total,
          sum(tax_weight) over(order by starts_at,id) tax_cumulative,sum(tax_weight) over() tax_total from weights
      )
      update public.rental_pricing_periods period set
        rental_amount=case when shares.total=0 then 0 else
          round(new.rental_total*shares.cumulative/shares.total,2)-round(new.rental_total*(shares.cumulative-shares.weight)/shares.total,2) end,
        tax_amount=case when shares.tax_total=0 then 0 else
          round(new.tax_amount*shares.tax_cumulative/shares.tax_total,2)-round(new.tax_amount*(shares.tax_cumulative-shares.tax_weight)/shares.tax_total,2) end
      from shares where period.id=shares.id;
$block$;
 execute replace(definition,old_block,new_block);
end $$;

-- Settlement descriptions follow actual receipts and the resulting balance.
-- Retain the existing restriction on increasing a fully settled invoice.
do $$ declare definition text; old_block text; begin
 select pg_get_functiondef('public.admin_apply_manual_rental_discount(uuid,text,numeric,text,uuid,uuid)'::regprocedure) into definition;
 definition:=replace(definition,'  v_requires_resign boolean;','  v_requires_resign boolean;'||chr(10)||'  v_net_paid numeric;');
 old_block:=$old$  v_settlement_status := case
    when lower(coalesce(v_rental.payment_status, 'pending')) <> 'paid'
      then 'unpaid_repriced'
    when v_total_delta < -0.005 then 'customer_credit_due'
    when v_total_delta > 0.005 then 'customer_charge_pending'
    else 'no_change'
  end;
  if v_settlement_status = 'customer_charge_pending' then$old$;
 if position(old_block in definition)=0 then raise exception 'Review discount settlement logic before upgrading.'; end if;
 definition:=replace(definition,old_block,$new$  v_net_paid := public.rentmect_rental_net_paid_amount(v_rental.id);
  v_settlement_status := case
    when v_net_paid <= 0 then 'unpaid_repriced'
    when v_new_total > v_net_paid + 0.005 then 'customer_charge_pending'
    when v_new_total < v_net_paid - 0.005 then 'customer_credit_due'
    else 'no_change'
  end;
  if v_total_delta > 0.005 and v_net_paid >= v_old_total - 0.005 and v_net_paid > 0 then$new$);
 definition:=replace(definition,$find$case when v_settlement_status = 'customer_credit_due' then abs(v_total_delta) else 0 end$find$,
   $replace$case when v_settlement_status = 'customer_credit_due' then round(v_net_paid-v_new_total,2) else 0 end$replace$);
 definition:=replace(definition,$find$when lower(coalesce(payment_status, 'pending')) <> 'paid'$find$,'when v_net_paid <= 0');
 definition:=replace(definition,$find$to_char(abs(v_total_delta), 'FM$999,999,990.00')$find$,$replace$to_char(greatest(0,v_net_paid-v_new_total), 'FM$999,999,990.00')$replace$);
 definition:=replace(definition,$find$else 'Your unpaid checkout total has been updated.'$find$,$message$when 'customer_charge_pending' then 'Your remaining rental balance is '||to_char(greatest(0,v_new_total-v_net_paid),'FM$999,999,990.00')||'. Payments already received remain credited.'
        when 'no_change' then 'Your recorded payments cover the updated rental total.'
        else 'Your unpaid checkout total has been updated.'$message$);
 execute definition;
end $$;
notify pgrst,'reload schema';
commit;
