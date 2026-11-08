-- Synthetic rollback-only regression. Never run customer writes as a test.
\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='service_role';
\ir fixtures/account_fixture.sql

create function pg_temp.closeout_fixture() returns uuid language plpgsql as $$
declare rid uuid;
begin
 rid:=pg_temp.account_fixture(300,806.80); -- $813.67 invoice less $6.87 rental balance
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',inspection_completed_at=now(),payment_provider='local' where id=rid;
 perform set_config('session_replication_role','origin',true);
 insert into rental_deposit_allocations(source_rental_id,holder_rental_id,payment_provider,amount_held,status)
 values(rid,rid,'local',300,'held');
 perform sync_rental_remaining_balance(rid,auth.uid());
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,taxable,total_amount)
 select rid,user_id,'Synthetic '||label,type,amount,false,amount from rentals,
 (values('fuel','fuel',72.57),('day','late_rental_day',76.30),('late fee','late_fee',26.59)) as x(label,type,amount)
 where id=rid;
 return rid;
end$$;
create function pg_temp.closeout(rid uuid,k uuid default gen_random_uuid()) returns jsonb language plpgsql as $$
declare aid uuid; ids uuid[]; snap jsonb;
begin
 select id into aid from rental_deposit_allocations where holder_rental_id=rid;
 select array_agg(id),jsonb_agg(to_jsonb(c)) into ids,snap from rental_charge_items c
 where rental_id=rid and status in ('pending','failed','checkout_open') and charge_type<>'rental_installment';
 return service_deduct_deposit_charges(rid,aid,ids,182.33,117.67,snap,
  (select to_jsonb(a) from rental_deposit_allocations a where id=aid),auth.uid(),'Synthetic deposit closeout',k);
end$$;

do $$declare rid uuid:=pg_temp.closeout_fixture(); aid uuid; ids uuid[]; k uuid:=gen_random_uuid(); result jsonb; begin
 select id into aid from rental_deposit_allocations where holder_rental_id=rid;
 select array_agg(id) into ids from rental_charge_items where rental_id=rid and status='pending';
 result:=pg_temp.closeout(rid,k);
 assert (result->>'applied')::numeric=182.33 and (result->>'remaining')::numeric=117.67;
 assert (select count(*)=4 and sum(amount)=182.33 from rental_deposit_charge_applications where rental_id=rid);
 assert (select count(*)=4 and sum(payment_amount_cents)=0 from rental_charge_items where rental_id=rid and payment_provider='deposit' and status='paid');
 assert rentmect_rental_net_paid_amount(rid)=813.67;
 assert (select payment_amount_cents=80680 and payment_status='paid' and deposit_held_amount=117.67 and deposit_released_amount=0 from rentals where id=rid);
 assert (select count(*)=0 from rental_charge_items where rental_id=rid and status in ('pending','failed','checkout_open'));
 perform sync_rental_remaining_balance(rid,auth.uid());
 assert (select deposit_held_amount=117.67 from rentals where id=rid),'Reconciliation restored consumed collateral';
 begin
  perform admin_record_external_deposit_release(rid,'cash_app','synthetic','Reported prior return',124.54);
  raise exception 'Wrong refund accepted';
 exception when others then if SQLERRM not like '%remainder changed%' then raise; end if; end;
 perform admin_record_external_deposit_release(rid,'cash_app','synthetic','Reported prior return',117.67);
 assert (select amount_applied=182.33 and amount_released=117.67 and external_return_method='cash_app' and refund_completed_at is not null from rental_deposit_allocations where id=aid);
 assert (select deposit_held_amount=0 and deposit_released_amount=117.67 and payment_status='paid' from rentals where id=rid);
 perform sync_rental_remaining_balance(rid,auth.uid());
 assert (select deposit_held_amount=0 from rentals where id=rid),'Reconciliation restored returned collateral';
 assert (select count(*)=1 from rental_deposit_allocations where holder_rental_id=rid);
 result:=service_deduct_deposit_charges(rid,aid,ids,182.33,117.67,'[]',null,auth.uid(),'Synthetic deposit closeout',k);
 assert (result->>'duplicate')::boolean;
 begin
  perform admin_record_external_deposit_release(rid,'cash_app','synthetic','Duplicate return',117.67);
  raise exception 'Duplicate return accepted';
 exception when others then if SQLERRM not like '%remainder changed%' then raise; end if; end;
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS exact $300 = $182.33 applied + $117.67 returned; four entries; cash unchanged; resync and retries safe';
end$$;

do $$declare rid uuid; cid uuid; begin
 rid:=pg_temp.closeout_fixture();
 perform set_config('session_replication_role','replica',true);
 update rentals set status='active' where id=rid;
 perform set_config('session_replication_role','origin',true);
 begin perform pg_temp.closeout(rid); raise exception 'Active invoice consumed deposit';
 exception when others then if SQLERRM not like '%after return%' then raise; end if; end;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed' where id=rid;
 perform set_config('session_replication_role','origin',true);
 update rental_charge_items set amount=6.86,total_amount=6.86 where rental_id=rid and charge_type='rental_amendment';
 begin perform pg_temp.closeout(rid); raise exception 'Stale debt accepted';
 exception when others then if SQLERRM not like '%exact remainder%' then raise; end if; end;
 update rental_charge_items set amount=6.87,total_amount=6.87 where rental_id=rid and charge_type='rental_amendment';
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount,status)
 select id,user_id,'Synthetic concurrent checkout','rental_installment',6.87,6.87,'pending' from rentals where id=rid returning id into cid;
 begin perform pg_temp.closeout(rid); raise exception 'Concurrent installment accepted';
 exception when others then if SQLERRM not like '%other rental payment attempts%' then raise; end if; end;
 update rental_charge_items set status='waived' where id=cid;
 perform pg_temp.closeout(rid);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS active rental, stale debt, and competing installment blocked';
end$$;
rollback;
