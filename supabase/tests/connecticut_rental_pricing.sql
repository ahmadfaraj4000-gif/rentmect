\set ON_ERROR_STOP on
begin;
\ir fixtures/account_fixture.sql
do $$
declare fixture uuid:=pg_temp.account_fixture(0,0); car vehicles; renter uuid; q jsonb; invoice rentals; fee rental_charge_items; s jsonb; ext jsonb;
begin
  assert ct_passenger_rental_rate(30,50001)=0.0935;
  assert ct_passenger_rental_rate(31,50000)=0.0635;
  assert ct_passenger_rental_rate(31,50000.01)=0.0775;
  assert ct_passenger_rental_rate(31,null) is null;
  assert ct_tourism_surcharge(30)=30 and ct_tourism_surcharge(31)=0;
  select user_id into renter from rentals where id=fixture;
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
  insert into vehicles(name,daily_rate,security_deposit,published,status,is_active,agreed_vehicle_value)
  values('Synthetic pricing test',40,0,false,'available',true,50000) returning * into car;
  q:=get_booking_quote(car.id,current_date+60,current_date+65);
  assert (q->>'total_due_today')::numeric=223.70, q::text;
  q:=get_booking_quote(car.id,current_date+60,current_date+91);
  assert (q->>'total_due_today')::numeric=1318.74, q::text;
  perform set_config('session_replication_role','replica',true);
  update rentals set status='cancelled' where id=fixture;
  perform set_config('session_replication_role','origin',true);
  perform set_config('request.jwt.claim.sub',renter::text,true);
  invoice:=create_rental_with_lock(car.id,current_date+60,current_date+65);
  assert invoice.contract_sales_tax_rate=0.0935 and invoice.tax_amount=18.70 and invoice.service_fee_total=5, to_jsonb(invoice)::text;
  assert rentmect_rental_invoice_total(invoice.id)=223.70;
  perform set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
  ext:=rentmect_build_extension_quote_before_periods(invoice.id,car.id,'same_vehicle_extension',current_date+67,'9:00 AM');
  assert (ext->>'extension_total_amount')::numeric=89.48 and (ext->>'tourism_surcharge')::numeric=2, ext::text;
  ext:=rentmect_build_extension_quote_before_periods(invoice.id,car.id,'switch_car_continuation',current_date+96,'9:00 AM');
  assert (ext->>'extension_tax_amount')::numeric=78.74 and (ext->>'tourism_surcharge')::numeric=0, ext::text;
  begin
    perform rentmect_build_extension_quote_before_periods(invoice.id,car.id,'same_vehicle_extension',current_date+96,'9:00 AM');
    raise exception 'Crossing 30 days silently produced a quote';
  exception when raise_exception then
    if sqlerrm not like 'This amendment takes the original short-term agreement past 30 days.%' then raise; end if;
  end;
  fee:=admin_add_rental_charge(invoice.id,'Extra mileage','excess_mileage',100);
  assert fee.total_amount=109.35 and fee.tax_amount=9.35;
  s:=rental_balance_statement(invoice.id);
  assert (s->>'due')::numeric=333.05 and position('tourism surcharge: $5.00' in s->>'statement')>0,s::text;
end $$;
rollback;
