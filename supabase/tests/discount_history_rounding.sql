-- Complete-schema regression. All synthetic records are rolled back.
begin;
alter table rental_amendments alter column created_at set default clock_timestamp();
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; q jsonb; result jsonb; before_paid jsonb; before_deposits jsonb;
 key uuid:=gen_random_uuid(); original_error text; before_count bigint;
begin
 rid:=pg_temp.account_fixture(300,300);
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_date=current_date-22,rental_total=1518,base_rental_total=1518,tax_amount=96.39 where id=rid;
 update rental_vehicle_assignments set assigned_from=rentmect_rental_timestamp(current_date-22,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,source_kind,payment_provider,amount_held,status)
 values(rid,rid,'local_payment','local',300,'held');
 perform admin_apply_manual_rental_discount(rid,'fixed',114.78,'Synthetic original discount',gen_random_uuid(),auth.uid());
 assert (select manual_discount_tax_savings=7.29 from rentals where id=rid);
 q:=admin_preview_rental_extension(rid,current_date+2,'9:00 AM',69,'Synthetic two-day extension');
 perform admin_apply_rental_extension(rid,current_date+2,'9:00 AM',69,'Synthetic two-day extension',gen_random_uuid(),q->>'revision');
 assert (select rental_total=1541.22 and tax_amount=97.86 and manual_discount_tax_savings=7.30 from rentals where id=rid);
 -- Establish the reported receipts through the real local-payment path.
 perform record_admin_rental_balance_payment(rid,1627,'cash','Synthetic incident receipt',auth.uid());
 assert rentmect_rental_net_paid_amount(rid)=1927;
 select jsonb_agg(c order by c.id) into before_paid from rental_charge_items c where rental_id=rid and status='paid';
 select jsonb_agg(d order by d.id) into before_deposits from rental_deposit_allocations d where holder_rental_id=rid;
 q:=admin_preview_manual_rental_discount(rid,'fixed',126.86);
 assert (q->>'new_total')::numeric=1926.24 and (q->>'paid_credit_due')::numeric=0.76;
 result:=admin_apply_manual_rental_discount(rid,'fixed',126.86,'Synthetic replacement discount',key,auth.uid());
 assert (result->'amendment'->>'credit_amount')::numeric=0.76;
 assert (select rental_total=1529.14 and tax_amount=97.10 and security_deposit=300 from rentals where id=rid);
 assert rentmect_rental_net_paid_amount(rid)=1927;
 assert (select jsonb_agg(c order by c.id) from rental_charge_items c where rental_id=rid and status='paid') is not distinct from before_paid;
 assert (select jsonb_agg(d order by d.id) from rental_deposit_allocations d where holder_rental_id=rid) is not distinct from before_deposits, jsonb_build_object('before',before_deposits,'after',(select jsonb_agg(d order by d.id) from rental_deposit_allocations d where holder_rental_id=rid))::text;
 result:=admin_apply_manual_rental_discount(rid,'fixed',126.86,'Synthetic replacement discount',key,auth.uid());
 assert (result->>'idempotent_replay')::boolean;
 perform rentmect_assert_period_financial_totals(rid);
 -- Preview must reject the same settled-credit increase as apply.
 begin perform admin_preview_manual_rental_discount(rid,'remove',0); raise exception 'Expected preview rejection';
 exception when others then assert sqlerrm like 'A paid rental discount cannot%'; end;
 -- Unpaid percentage, replacement, removal, and fully comped histories.
 rid:=pg_temp.account_fixture(300,0);
 perform admin_apply_manual_rental_discount(rid,'percentage',10,'Synthetic percent discount',gen_random_uuid(),auth.uid());
 perform admin_apply_manual_rental_discount(rid,'percentage',100,'Synthetic full rental comp',gen_random_uuid(),auth.uid());
 perform admin_apply_manual_rental_discount(rid,'remove',0,'Synthetic discount removal',gen_random_uuid(),auth.uid());
 assert (select rental_total=483 and tax_amount=30.67 and security_deposit=300 from rentals where id=rid);
 -- Genuine corruption still fails BEFORE a price is offered and before writes.
 perform admin_apply_manual_rental_discount(rid,'fixed',20,'Synthetic corruption fixture',gen_random_uuid(),auth.uid());
 update rental_amendments set new_values=jsonb_set(new_values,'{pricing_periods,0,tax_amount}','123.45') where rental_id=rid and new_values->>'manual_discount_amount'='20.00';
 select count(*) into before_count from rental_amendments where rental_id=rid;
 begin perform admin_preview_manual_rental_discount(rid,'fixed',25); raise exception 'Corrupt preview was accepted';
 exception when others then original_error:=sqlerrm; assert original_error like 'Discount amendment totals%'; end;
 begin perform admin_apply_manual_rental_discount(rid,'fixed',25,'Synthetic rejected adjustment',gen_random_uuid(),auth.uid()); raise exception 'Corrupt apply was accepted';
 exception when others then assert sqlerrm=original_error; end;
 assert (select count(*) from rental_amendments where rental_id=rid)=before_count;
end $$;
set constraints all immediate;
rollback;
