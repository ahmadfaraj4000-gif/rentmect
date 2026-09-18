-- Executable regression using the reviewed rental as a rollback-only fixture.
-- No provider calls, committed data changes, emails, or money movement.
begin;
select set_config('request.jwt.claims',jsonb_build_object('role','service_role','sub',
 (select id from public.profiles where role='admin' order by created_at limit 1))::text,true);
do $$
declare
 rid uuid:='11d66efa-1efa-4531-928e-8956cc47210c';
 cid uuid:='f6a9347f-39ad-4162-8855-68dff3252e18';
 actor uuid:=auth.uid(); aid uuid; pi text; result jsonb; msg text; stamp timestamptz;
begin
 select id,stripe_payment_intent_id into aid,pi from public.rental_deposit_allocations
 where holder_rental_id=rid and status='held' and amount_held=300 and amount_applied=0;
 if aid is null or not exists(select 1 from public.rental_charge_items where id=cid and status='pending' and total_amount=56.38) then
  raise exception 'Rollback fixture changed; do not skip settlement verification.';
 end if;
 -- Wrong amounts, duplicate selections, and wrong-rental charges fail before mutation.
 begin
  perform public.service_apply_deposit_to_charges(rid,array[cid],56.37,243.63,actor,'Rollback test');
  raise exception 'Stale amounts accepted';
 exception when others then if SQLERRM not like '%amounts changed%' then raise; end if; end;
 begin
  perform public.service_apply_deposit_to_charges(rid,array[cid,cid],112.76,187.24,actor,'Rollback test');
  raise exception 'Duplicate selections accepted';
 exception when others then if SQLERRM not like '%distinct charges%' then raise; end if; end;
 begin
  perform public.service_apply_deposit_to_charges(rid,array[gen_random_uuid()],56.38,243.62,actor,'Rollback test');
  raise exception 'Foreign charge accepted';
 exception when others then if SQLERRM not like '%selected charge changed%' then raise; end if; end;
 -- Any existing Checkout attempt is ineligible (no competing collection).
 begin
  update public.rental_charge_items set stripe_checkout_session_id='cs_rollback_only' where id=cid;
  begin
   perform public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Rollback test');
   raise exception 'Open Checkout accepted';
  exception when others then if SQLERRM not like '%payment attempt%' then raise; end if; end;
  raise exception using errcode='Z0001',message='rollback fixture';
 exception when sqlstate 'Z0001' then null; end;
 -- Another open charge must roll back the entire deduction, not just block refund.
 begin
  insert into public.rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount)
   select rid,user_id,'Rollback additional blocker','fuel',1,1 from public.rentals where id=rid;
  begin
   perform public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Rollback test');
   raise exception 'Other charge blocker ignored';
  exception when others then if SQLERRM not like '%Other unresolved%' then raise; end if; end;
  if exists(select 1 from public.rental_deposit_charge_applications where rental_id=rid) then raise exception 'Blocked settlement partly committed'; end if;
  raise exception using errcode='Z0001',message='rollback fixture';
 exception when sqlstate 'Z0001' then null; end;
 -- Service-only API boundary is enforced even with a valid staff actor.
 perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
 begin
  perform public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Rollback test');
  raise exception 'Non-service settlement accepted';
 exception when others then if SQLERRM not like '%Service role required%' then raise; end if; end;
 perform set_config('request.jwt.claims',jsonb_build_object('role','service_role','sub',actor)::text,true);
 -- Main 300 = 56.38 applied + 243.62 refundable case.
 begin
  result:=public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Fuel from deposit; rollback test');
  if result->>'refund'<>'243.62' then raise exception 'Wrong refund remainder'; end if;
  if (select amount_held from public.rental_deposit_allocations where id=aid)<>300
   or (select amount_applied from public.rental_deposit_allocations where id=aid)<>56.38
   or (select amount_released from public.rental_deposit_allocations where id=aid)<>0 then raise exception 'Capture or refund history corrupted'; end if;
  if (select deposit_held_amount from public.rentals where id=rid)<>243.62 then raise exception 'Wrong held summary'; end if;
  if not exists(select 1 from public.rental_charge_items where id=cid and status='paid' and payment_provider='deposit' and payment_amount_cents=0) then
   raise exception 'Charge not settled as an internal transfer'; end if;
  if public.rentmect_rental_net_paid_amount(rid)<>1384.81 then raise exception 'Applied funds counted as another rental receipt'; end if;
  result:=public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Fuel from deposit; rollback test');
  if result->>'duplicate'<>'true' or (select count(*) from public.rental_deposit_charge_applications where rental_id=rid)<>1 then raise exception 'Duplicate application'; end if;
  perform public.ensure_rental_deposit_allocation(rid);
  if (select count(*) from public.rental_deposit_allocations where holder_rental_id=rid)<>1 then raise exception 'Deposit recreated'; end if;
  perform public.service_reserve_deposit_refunds(rid);
  if (select refund_reserved_amount from public.rental_deposit_allocations where id=aid)<>243.62 then raise exception 'Wrong reserved refund'; end if;
  begin
   update public.rental_deposit_allocations set refund_reserved_amount=300,amount_applied=0 where id=aid;
   raise exception 'Reserved amount changed';
  exception when others then if SQLERRM not like '%cannot be resized%' then raise; end if; end;
  begin
   update public.rental_charge_items set status='waived' where id=cid;
   raise exception 'Applied charge waived';
  exception when others then if SQLERRM not like '%cannot be collected, waived, or changed%' then raise; end if; end;
  begin
   perform public.apply_stripe_deposit_refund(rid,aid,'re_settlement_rollback',pi,'succeeded',300,null);
   raise exception 'Full refund after retention allowed';
  exception when others then if SQLERRM not like '%Invalid deposit refund%' then raise; end if; end;
  perform public.apply_stripe_deposit_refund(rid,aid,'re_settlement_rollback',pi,'failed',243.62,'rollback failure');
  if (select amount_applied from public.rental_deposit_allocations where id=aid)<>56.38 or
    (select amount_released from public.rental_deposit_allocations where id=aid)<>0 then raise exception 'Failed refund reversed deduction'; end if;
  perform public.apply_stripe_deposit_refund(rid,aid,'re_settlement_rollback',pi,'succeeded',243.62,null);
  if (select deposit_status from public.rentals where id=rid)<>'released' or
    (select deposit_held_amount from public.rentals where id=rid)<>0 or
    (select deposit_released_amount from public.rentals where id=rid)<>243.62 then raise exception 'Wrong final summary'; end if;
  select deposit_released_at into stamp from public.rentals where id=rid;
  perform public.apply_stripe_deposit_refund(rid,aid,'re_settlement_rollback',pi,'pending',243.62,null);
  if (select deposit_released_at from public.rentals where id=rid)<>stamp or
    (select deposit_status from public.rentals where id=rid)<>'released' then raise exception 'Late webhook reversed settlement'; end if;
  perform public.ensure_rental_deposit_allocation(rid);
  if (select count(*) from public.rental_deposit_allocations where holder_rental_id=rid)<>1 then raise exception 'Settled deposit recreated'; end if;
  set constraints all immediate;
  raise exception using errcode='Z0001',message='rollback fixture';
 exception when sqlstate 'Z0001' then null; end;
 -- A normal refund reservation must win over a competing deduction.
 begin
  update public.rental_charge_items set status='waived' where id=cid;
  perform public.service_reserve_deposit_refunds(rid);
  if (select refund_reserved_amount from public.rental_deposit_allocations where id=aid)<>300 then raise exception 'Ordinary refund changed'; end if;
  update public.rental_charge_items set status='pending' where id=cid;
  begin
   perform public.service_apply_deposit_to_charges(rid,array[cid],56.38,243.62,actor,'Rollback test');
   raise exception 'Deduction after refund reservation allowed';
  exception when others then if SQLERRM not like '%untransferred held deposit%' then raise; end if; end;
  raise exception using errcode='Z0001',message='rollback fixture';
 exception when sqlstate 'Z0001' then null; end;
 if has_function_privilege('authenticated','public.service_apply_deposit_to_charges(uuid,uuid[],numeric,numeric,uuid,text)','EXECUTE') or
    has_function_privilege('authenticated','public.service_reserve_deposit_refunds(uuid)','EXECUTE') then raise exception 'Untrusted settlement access'; end if;
 raise notice 'Deposit settlement regressions passed';
end $$;
rollback;
