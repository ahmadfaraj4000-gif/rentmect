\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
-- Definition inventory catches a hidden server-side minimum, including nested
-- predicates used to determine whether an override has actually been satisfied.
do $$ declare f record; line text; begin
 for f in select proname,prosrc from pg_proc join pg_namespace n on n.oid=pronamespace
 where n.nspname='public' and (proname like 'admin_%' or proname like 'service_%' or proname in ('enforce_rental_odometer_gate','reserve_rental_payment_refund','prepare_before_pickup_deposit_refund')) loop
 foreach line in array string_to_array(f.prosrc,E'\n') loop
  if line ~* '(reason|note)' and line ~* 'length\(' and line ~ '(<|>=)[[:space:]]*(3|5|8|10|20)\M' then
   raise exception 'Remaining reason minimum in %: %',f.proname,line;
  end if;
 end loop;
 end loop;
end $$;
do $$ declare rid uuid; q jsonb; changed jsonb; replacement uuid; key uuid; begin
 rid:=pg_temp.account_fixture();
 q:=admin_preview_rental_extension(rid,current_date+3,'9:00 AM',69,'x');
 changed:=admin_apply_rental_extension(rid,current_date+3,'9:00 AM',69,'x',gen_random_uuid(),q->>'revision');
 assert (select status='active' from rentals where id=rid);
 begin
  perform admin_preview_rental_extension(rid,current_date+4,'9:00 AM',69,'   ');
  raise exception 'Whitespace reason accepted';
 exception when others then assert sqlerrm<>'Whitespace reason accepted' and sqlerrm ilike '%reason%',sqlerrm;end;
 insert into vehicles(name,daily_rate,security_deposit,status,is_active,published,current_mileage)
 values('Short reason replacement',69,300,'available',true,false,0) returning id into replacement;
 q:=admin_preview_vehicle_swap(rid,replacement,now()-interval '1 minute','maintenance','x',null,1100,0);
 changed:=admin_apply_vehicle_swap(rid,replacement,now()-interval '1 minute','maintenance','x',null,gen_random_uuid(),q->>'revision',1100,0);
 assert (select vehicle_id=replacement from rentals where id=rid);
 perform admin_inspect_and_complete_rental_return(rid,100,true,true,true,true,'hold','x','maintenance',false,null);
 assert (select status='completed' from rentals where id=rid);
 assert exists(select 1 from rental_audit_events where rental_id=rid);
 raise notice 'PASS: one-character extension/swap/return reasons; whitespace rejected; audit and state retained';
end $$;
do $$ declare rid uuid; begin
 rid:=pg_temp.account_fixture();
 perform admin_inspect_and_complete_rental_return(rid,1,true,true,true,false,'hold','x','available',true,null);
 assert (select status='completed' from rentals where id=rid);
 assert exists(select 1 from rental_return_inspections where rental_id=rid and mileage_override and notes='x');
 raise notice 'PASS: explicit odometer override accepts a one-character audited note';
end $$;
do $$ declare rid uuid; cid uuid; result jsonb; preview jsonb; req jsonb; key uuid; begin
 rid:=pg_temp.account_fixture(300,0);
 perform set_config('request.jwt.claim.role','service_role',true);
 result:=record_admin_rental_balance_payment(rid,813.67,'cash','Synthetic receipt',auth.uid());
 cid:=(result->'payment'->>'id')::uuid; key:=gen_random_uuid();
 perform set_config('request.jwt.claim.role','authenticated',true);
 req:=jsonb_build_object('expectedAmountCents',81367,'amountCents',70000,'paymentMethod','cash','receivedDate',current_date,'reason','x');
 preview:=admin_correct_payment_amount('rental_charge',cid,req,key);
 result:=admin_correct_payment_amount('rental_charge',cid,req,key,preview->>'reviewToken');
 assert result->>'status'='corrected';
 assert rentmect_rental_net_paid_amount(rid)=700;
 assert admin_correct_payment_amount('rental_charge',cid,req,key,preview->>'reviewToken')=result;
 assert (select count(*)=1 from payment_amount_corrections where id=key);
 raise notice 'PASS: one-character payment correction, exact amounts and idempotent confirmation';
end $$;
rollback;
