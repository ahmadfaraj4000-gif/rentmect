begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; q jsonb; k uuid:=gen_random_uuid(); begin
 rid:=pg_temp.account_fixture(400,0);
 perform set_config('session_replication_role','replica',true);
 update rentals set rental_total=553,base_rental_total=553,tax_amount=35.12,pre_manual_discount_rental_total=null where id=rid;
 perform set_config('session_replication_role','origin',true);
 q:=admin_preview_manual_rental_discount(rid,'target',650);
 assert (q->>'manual_discount_amount')::numeric=317.93,q::text;
 assert (q->>'tax_amount')::numeric=14.93 and (q->>'total_balance_due')::numeric=650,q::text;
 perform admin_apply_manual_rental_discount(rid,'target',650,'Synthetic desired balance',k,auth.uid());
 assert rentmect_rental_invoice_total(rid)=650;
 assert (select security_deposit=400 and manual_discount_type='fixed' from rentals where id=rid);
 q:=admin_apply_manual_rental_discount(rid,'target',650,'Synthetic desired balance',k,auth.uid());
 assert (q->>'idempotent_replay')::boolean;
 begin perform admin_preview_manual_rental_discount(rid,'target',399); raise exception 'Expected minimum rejection'; exception when others then assert sqlerrm like 'That balance is below%'; end;
 rid:=pg_temp.account_fixture(400,100);
 q:=admin_preview_manual_rental_discount(rid,'target',450);
 assert (q->>'total_balance_due')::numeric=450 and (q->>'net_paid')::numeric=100,q::text;
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount,status,source_type)
 select id,user_id,'Synthetic additional charge','service_fee',50,50,'pending','manual' from rentals where id=rid;
 q:=admin_preview_manual_rental_discount(rid,'target',450);
 assert (q->>'additional_charges_due')::numeric=50 and (q->>'total_balance_due')::numeric=450,q::text;
end $$;
rollback;
