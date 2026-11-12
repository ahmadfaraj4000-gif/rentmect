\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql

do $$
declare rid uuid; cid uuid; aid uuid; k uuid; req jsonb; result jsonb; rows jsonb; total numeric; source_amount numeric; i integer;
begin
 for i in 1..3 loop
  total:=case when i=3 then 250 else 120 end;
  rid:=pg_temp.account_fixture(180,693.67);k:=gen_random_uuid();
  perform set_config('session_replication_role','replica',true);
  update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now() where id=rid;
  perform set_config('session_replication_role','origin',true);
  if i=2 then
   insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status,stripe_payment_intent_id)
    values(rid,rid,'local',90,'held',null),(rid,rid,'stripe',90,'held','pi_review_mix');
  else
   insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
    values(rid,rid,'local',180,'held');
  end if;
  insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount,source_type)
   select rid,user_id,'Documented cleaning','cleaning',total,false,total,'manual' from rentals where id=rid returning id into cid;
  req:=jsonb_build_object('chargeIds',jsonb_build_array(cid),'expectedHeld',180,'expectedCharges',total,'reason','Reviewed documented return charges.');
  begin
   perform service_apply_deposit_review(gen_random_uuid(),rid,auth.uid(),req||'{"expectedHeld":999}',
    (select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
   raise exception 'Stale preview accepted';
  exception when others then if sqlerrm not like '%amounts changed%' then raise; end if; end;
  result:=service_apply_deposit_review(k,rid,auth.uid(),req,
   (select jsonb_agg(c) from rental_charge_items c where id=cid),(select jsonb_agg(a) from rental_deposit_allocations a where holder_rental_id=rid));
  assert (result->>'applied')::numeric=least(total,180);
  assert (result->>'remaining')::numeric=greatest(0,180-total);
  assert (select sum(amount_applied)=least(total,180) from rental_deposit_allocations where holder_rental_id=rid);
  assert (select allocated_deposit_cents=least(total,180)*100 and rentmect_charge_remaining_amount(c)=greatest(0,total-180) from rental_charge_items c where id=cid);
  assert (select sum(amount)=least(total,180) from rental_deposit_charge_applications where charge_id=cid);
  assert service_apply_deposit_review(k,rid,auth.uid(),req,'[]','[]')=result;
  if i=2 then
   assert (select amount_applied=90 from rental_deposit_allocations where holder_rental_id=rid and payment_provider='local');
   assert (select amount_applied=30 from rental_deposit_allocations where holder_rental_id=rid and payment_provider='stripe');
  end if;
  perform set_config('request.jwt.claim.role','authenticated',true);
  rows:=admin_rental_list('deposit_review','',0,5,rid);
  assert (rows->'counts'->>'deposit_review')::integer>=case when i=3 then 0 else 1 end;
  if i=1 then
   perform admin_hold_deposit_review(rid,'Waiting for toll confirmation',now()+interval '1 day');
   assert (select deposit_review_approved_at is null and deposit_release_due_at is null from rentals where id=rid);
   perform admin_record_external_deposit_release(rid,'cash','synthetic return','Remainder returned',60);
   assert (select not rentmect_needs_deposit_review(r) from rentals r where id=rid);
  end if;
  perform set_config('request.jwt.claim.role','service_role',true);
 end loop;
 for i in 1..6 loop
  rid:=pg_temp.account_fixture(0,513.67);
  perform set_config('session_replication_role','replica',true);
  update rentals set status='completed',ending_mileage=1200,inspection_completed_at=now(),deposit_status='waived' where id=rid;
  perform set_config('session_replication_role','origin',true);
 end loop;
 perform set_config('request.jwt.claim.role','authenticated',true);
 rows:=admin_rental_list('archive','',0,5,null);
 assert jsonb_array_length(rows->'rows')=5 and (rows->>'total')::integer>=6;
 rows:=admin_rental_list('deposit_review','',0,5,null);
 assert (rows->>'total')::integer=1;
 raise notice 'PASS: $180 less $120 leaves $60; mixed sources; insufficient deposit; idempotent deduction; hold and external return';
end $$;
set constraints all immediate;
rollback;
