select set_config('request.jwt.claim.role','service_role',false);
insert into profiles(id,role,staff_role) values('11111111-1111-4111-8111-111111111111','admin','owner');
insert into rentals(id,user_id,vehicle_id,pickup_date,pickup_time,return_date,return_time,status,
 rental_total,base_rental_total,tax_amount,security_deposit,payment_status,manual_discount_amount)
values('22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333',gen_random_uuid(),
 '2026-10-24','1:30 AM','2026-11-02','6:00 PM','active',531,531,33.72,300,'pending',0);
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','percentage',5,'Original booking discount',
 '44444444-4444-4444-8444-444444444441','11111111-1111-4111-8111-111111111111');
-- A later extension is quoted separately and does not inherit the earlier discount.
insert into rental_admin_extensions(id,rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount)
values('55555555-5555-4555-8555-555555555555','22222222-2222-4222-8222-222222222222','2026-11-02T23:00Z','2026-11-03T23:00Z',69,1,0,69,4.38);
select set_config('rentmect.admin_extension','55555555-5555-4555-8555-555555555555',false);
update rentals set return_date='2026-11-03',pre_manual_discount_rental_total=600,pre_manual_discount_tax_amount=38.10
 where id='22222222-2222-4222-8222-222222222222';
select set_config('rentmect.admin_extension','',false);
insert into test_receipts values('22222222-2222-4222-8222-222222222222',836.48);
update rentals set payment_status='partially_paid',payment_amount_cents=83648 where id='22222222-2222-4222-8222-222222222222';
-- Existing discounts predate the new basis field; reconstruct from audit snapshots.
update rental_amendments set new_values=new_values-'discount_period_basis';
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','remove',0,'Intentional removal reviewed',
 '44444444-4444-4444-8444-444444444442','11111111-1111-4111-8111-111111111111');
do $$declare r rentals; a rental_amendments; begin
 select * into r from rentals where id='22222222-2222-4222-8222-222222222222';
 assert r.rental_total=600 and r.tax_amount=38.10;
 assert r.payment_amount_cents=83648,'Captured receipt snapshot must remain unchanged';
 assert (select rental_amount=531 and tax_amount=33.72 from rental_pricing_periods where source='booking_snapshot');
 assert (select rental_amount=69 and tax_amount=4.38 from rental_pricing_periods where source='extension');
 select * into a from rental_amendments where idempotency_key='44444444-4444-4444-8444-444444444442';
 assert a.settlement_status='customer_charge_pending','Partially paid rental must not be labelled unpaid';
 assert a.credit_amount=0;
 assert a.new_values ? 'discount_period_basis';
end $$;
-- A same-key replay does not reallocate or duplicate an amendment.
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','remove',0,'Intentional removal reviewed',
 '44444444-4444-4444-8444-444444444442','11111111-1111-4111-8111-111111111111');
-- Replacing a discount uses gross bases, and removing it restores exact quotes.
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','fixed',40,'Whole rental courtesy credit',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','percentage',10,'Replace courtesy with percent',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','remove',0,'Remove replacement discount',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
do $$begin
 assert (select rental_amount=531 and tax_amount=33.72 from rental_pricing_periods where source='booking_snapshot');
 assert (select rental_amount=69 and tax_amount=4.38 from rental_pricing_periods where source='extension');
 assert (select count(*)=1 from rental_amendments where idempotency_key='44444444-4444-4444-8444-444444444442');
end $$;
-- An actual credit is receipts minus the new invoice, not the entire discount.
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','fixed',200,'Discount leaves actual credit',
 '44444444-4444-4444-8444-444444444443','11111111-1111-4111-8111-111111111111');
do $$begin
 assert (select settlement_status='customer_credit_due' and credit_amount=111.08 from rental_amendments where idempotency_key='44444444-4444-4444-8444-444444444443');
 begin
  perform admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','remove',0,'Do not bypass existing credit',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
  raise exception 'Credit protection did not run';
 exception when others then if sqlerrm not like 'A paid rental discount cannot%' then raise; end if; end;
end $$;
-- Test projection over a split period and an untouched later extension.
do $$declare b jsonb; d jsonb; c jsonb; projected jsonb; begin
 b:='[{"starts_at":"2026-01-01T00:00Z","ends_at":"2026-01-03T00:00Z","rental_amount":100,"tax_amount":6.35}]';
 d:='[{"starts_at":"2026-01-01T00:00Z","ends_at":"2026-01-03T00:00Z","rental_amount":90,"tax_amount":5.71}]';
 c:='[{"starts_at":"2026-01-01T00:00Z","ends_at":"2026-01-02T00:00Z","rental_amount":45,"tax_amount":2.86},{"starts_at":"2026-01-02T00:00Z","ends_at":"2026-01-03T00:00Z","rental_amount":65,"tax_amount":4.12},{"starts_at":"2026-01-03T00:00Z","ends_at":"2026-01-04T00:00Z","rental_amount":69,"tax_amount":4.38}]';
 projected:=rentmect_project_discount_basis(c,b,d);
 assert (projected->0->>'rental_amount')::numeric=50;
 assert (projected->1->>'rental_amount')::numeric=70,'Keep later vehicle-rate delta';
 assert (projected->2->>'rental_amount')::numeric=69,'Later extension receives no earlier discount';
 assert (select sum((value->>'tax_amount')::numeric) from jsonb_array_elements(projected))=12.00;
 begin
  perform rentmect_project_discount_basis(jsonb_build_array(c->0),b,d);
  raise exception 'Missing discounted dates were not rejected';
 exception when others then if sqlerrm not like 'Discounted dates changed%' then raise; end if; end;
end $$;
-- Fully comped unpaid periods restore their bases without division by zero.
delete from test_receipts;
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','percentage',100,'Comp entire unpaid booking',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
select admin_apply_manual_rental_discount('22222222-2222-4222-8222-222222222222','remove',0,'Restore original unpaid quote',gen_random_uuid(),'11111111-1111-4111-8111-111111111111');
do $$begin
 assert (select rental_amount=531 and tax_amount=33.72 from rental_pricing_periods where source='booking_snapshot');
 assert (select rental_amount=69 and tax_amount=4.38 from rental_pricing_periods where source='extension');
 assert (select rental_total+tax_amount+security_deposit=938.10 from rentals where id='22222222-2222-4222-8222-222222222222');
end $$;
