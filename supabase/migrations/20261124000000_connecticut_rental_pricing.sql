begin;
-- PS 2019(2), CGS 12-665/666 and DRS SN 2011(10). The contract value is
-- the agreed vehicle value at inception, separate from the daily rental price.
alter table public.vehicles add column agreed_vehicle_value numeric(12,2) check (agreed_vehicle_value>0);
create function public.guard_vehicle_tax_value() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.agreed_vehicle_value is distinct from (case when tg_op='UPDATE' then old.agreed_vehicle_value end)
     and rental_operations_staff_name() is null then raise exception 'Rental operations access required.' using errcode='42501'; end if;
  return new;
end $$;
create trigger guard_vehicle_tax_value before insert or update of agreed_vehicle_value on public.vehicles
for each row execute function public.guard_vehicle_tax_value();
alter table public.rentals add column contract_sales_tax_rate numeric(6,5),
  add column tourism_surcharge numeric(8,2) not null default 0 check(tourism_surcharge>=0);
create function public.ct_passenger_rental_rate(p_days integer,p_agreed_value numeric)
returns numeric language sql immutable set search_path='' as $$
  select case when p_days<1 or p_days is null then null when p_days<=30 then 0.0935
    when p_agreed_value is null or p_agreed_value<=0 then null when p_agreed_value>50000 then 0.0775 else 0.0635 end
$$;
create function public.ct_tourism_surcharge(p_days integer) returns numeric language sql immutable set search_path='' as $$
  select case when p_days between 1 and 30 then p_days else 0 end::numeric
$$;
-- Keep the existing quote's calendar, vehicle eligibility, discounts and age pricing.
alter function public.get_booking_quote(uuid,date,date,text,text) rename to get_booking_quote_before_ct_tax;
revoke all on function public.get_booking_quote_before_ct_tax(uuid,date,date,text,text) from public,anon,authenticated;
create function public.get_booking_quote(p_vehicle_id uuid,p_pickup_date date,p_return_date date,p_pickup_time text default '9:00 AM',p_return_time text default '9:00 AM')
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q jsonb; days integer; rate numeric; surcharge numeric; tax numeric; young_tax numeric;
begin
  q:=get_booking_quote_before_ct_tax(p_vehicle_id,p_pickup_date,p_return_date,p_pickup_time,p_return_time);
  if not (q->>'valid')::boolean or p_vehicle_id is null then return q; end if;
  days:=(q->>'billable_days')::integer;
  select ct_passenger_rental_rate(days,agreed_vehicle_value) into rate from vehicles where id=p_vehicle_id;
  if rate is null then return q||jsonb_build_object('valid',false,'error','Contact Rent Me CT for a long-term quote. The agreed vehicle value is required.'); end if;
  surcharge:=ct_tourism_surcharge(days);
  tax:=round((q->>'base_rental_total')::numeric*rate,2); young_tax:=round((q->>'under_25_rental_total')::numeric*rate,2);
  return q||jsonb_build_object('tax_rate',rate,'tourism_surcharge',surcharge,'tax_amount',tax,'under_25_tax_amount',young_tax,
    'total_due_today',(q->>'total_due_today')::numeric-(q->>'tax_amount')::numeric+tax+surcharge,
    'under_25_total_due_today',(q->>'under_25_total_due_today')::numeric-(q->>'under_25_tax_amount')::numeric+young_tax+surcharge);
end $$;
revoke all on function public.get_booking_quote(uuid,date,date,text,text) from public;
grant execute on function public.get_booking_quote(uuid,date,date,text,text) to anon,authenticated,service_role;

create function public.set_initial_contract_tax() returns trigger language plpgsql security definer set search_path=public as $$
declare days integer;
begin
  days:=rentmect_billable_days(new.pickup_date,new.pickup_time,new.return_date,new.return_time);
  select ct_passenger_rental_rate(days,agreed_vehicle_value) into new.contract_sales_tax_rate from vehicles where id=new.vehicle_id;
  if new.contract_sales_tax_rate is null then raise exception 'Record an agreed vehicle value before quoting this long-term rental.'; end if;
  new.tourism_surcharge:=ct_tourism_surcharge(days);
  return new;
end $$;
create trigger aaaa_initial_contract_tax before insert on public.rentals for each row execute function public.set_initial_contract_tax();
revoke all on function public.set_initial_contract_tax() from public,anon,authenticated;
create function public.contract_tax_rate(p_rental uuid) returns numeric language sql stable security definer set search_path=public as $$
  select coalesce(contract_sales_tax_rate,0.0635) from rentals where id=p_rental
$$;
revoke all on function public.contract_tax_rate(uuid) from public,anon,authenticated;
grant execute on function public.contract_tax_rate(uuid) to service_role;

-- Determine the original term for a newly assessed fee on a pre-migration rental.
-- Previously posted charges keep their stored tax amounts.
create function public.ct_new_charge_rate(r public.rentals) returns numeric
language plpgsql stable security definer set search_path=public as $$
declare original jsonb; original_end date; original_time text; days integer; value numeric; rate numeric;
begin
  if r.contract_sales_tax_rate is not null then return r.contract_sales_tax_rate; end if;
  select new_values into original from admin_audit_logs where entity_type='rental' and entity_id=r.id::text
    and action='rental.insert' order by created_at,id limit 1;
  if original is null then
    select original_return_date,original_return_time into original_end,original_time from rental_extension_requests
      where rental_id=r.id and status='activated' order by created_at,id limit 1;
    if exists(select from rental_admin_extensions where rental_id=r.id) then
      raise exception 'Review the original signed term before assessing tax on this historical rental.'; end if;
  end if;
  days:=rentmect_billable_days(coalesce((original->>'pickup_date')::date,r.pickup_date),
    coalesce(original->>'pickup_time',r.pickup_time),coalesce((original->>'return_date')::date,original_end,r.return_date),
    coalesce(original->>'return_time',original_time,r.return_time));
  select agreed_vehicle_value into value from vehicles where id=coalesce((original->>'vehicle_id')::uuid,r.vehicle_id);
  rate:=ct_passenger_rental_rate(days,value);
  if rate is null then raise exception 'Record the agreed vehicle value for the original long-term agreement before assessing this charge.'; end if;
  return rate;
end $$;
revoke all on function public.ct_new_charge_rate(public.rentals) from public,anon,authenticated;

-- Preserve existing settlement paths and posted amounts. New agreements carry their
-- own tax rate; existing invoices retain the historical pricing convention.
do $$ declare x record; f record; d text; begin
 for x in select * from (values
  ('apply_rentmect_rental_pricing','coalesce(new.contract_sales_tax_rate,0.0635)'),
  ('admin_add_rental_charge','public.ct_new_charge_rate(v_rental)'),
  ('snapshot_rental_service_fees','coalesce(new.contract_sales_tax_rate,0.0635)'),
  ('reprice_reserved_rental_discount','coalesce(new.contract_sales_tax_rate,0.0635)'),
  ('sync_manual_discount_snapshots_on_rental','coalesce(new.contract_sales_tax_rate,0.0635)'),
  ('apply_customer_discount_to_rental','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_manual_rental_discount_before_target','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_manual_rental_discount','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_rental_amendment','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_rental_amendment_without_manual_discount','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_rental_rate_change','public.contract_tax_rate(p_rental_id)'),
  ('admin_apply_rental_rate_change','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_vehicle_swap','public.contract_tax_rate(p_rental_id)'),
  ('admin_apply_vehicle_swap_before_mileage','public.contract_tax_rate(p_rental_id)'),
  ('admin_apply_vehicle_swap','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_rental_extension','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_rental_extension_revision','public.contract_tax_rate(p_rental_id)'),
  ('admin_preview_extension_rate','public.contract_tax_rate(r.id)'),
  ('rentmect_manual_discount_period_basis','public.contract_tax_rate(p_rental_id)'),
  ('rentmect_build_extension_quote_before_periods','public.contract_tax_rate(p_rental_id)'),
  ('apply_rentmect_extension_age_markup','public.contract_tax_rate(new.rental_id)'),
  ('apply_rentmect_extension_elapsed_day_billing','public.contract_tax_rate(new.rental_id)'),
  ('rentmect_freeze_extension_quote','public.contract_tax_rate(new.rental_id)'),
  ('decide_admin_rental_extension','public.contract_tax_rate(v_rental.id)')
 ) mapping(name,rate) loop
  for f in select oid from pg_proc where pronamespace='public'::regnamespace and proname=x.name and position('0.0635' in prosrc)>0 loop
    d:=replace(pg_get_functiondef(f.oid),'0.0635',x.rate);
    if x.name='apply_rentmect_rental_pricing' then
      if position('new.service_fee_total := 0;' in d)=0 then raise exception 'Review current rental pricing trigger.'; end if;
      d:=replace(d,'greatest(coalesce(new.return_date - new.pickup_date, 0), 0)','public.rentmect_billable_days(new.pickup_date,new.pickup_time,new.return_date,new.return_time)');
      d:=replace(d,'new.service_fee_total := 0;','new.service_fee_total := new.tourism_surcharge;');
    end if;
    execute d;
  end loop;
 end loop;
end $$;
commit;
