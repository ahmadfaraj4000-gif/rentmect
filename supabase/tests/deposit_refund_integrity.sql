-- Run after 20260917210000 inside a transaction; all test writes roll back.
-- No Stripe/network calls. Existing receipt used only as a rollback fixture.
begin;
select set_config('request.jwt.claims',jsonb_build_object('role','service_role','sub',
  (select id from public.profiles where email='anconamgt@aol.com' and role='admin' limit 1))::text,true);
do $$
declare
  rid uuid := '11d66efa-1efa-4531-928e-8956cc47210c';
  aid uuid;
  receipt uuid;
  completed_id uuid;
  new_local_id uuid;
  previous_released numeric;
  payment_intent text;
  result jsonb;
  stamp timestamptz;
  n integer;
  msg text;
begin
  select id into aid from public.rental_deposit_allocations where holder_rental_id=rid and status='held' limit 1;
  select c.id into receipt from public.rental_charge_items c where c.rental_id=rid
    and c.status='paid' and c.payment_provider='local' and c.charge_type='rental_amendment' and c.total_amount>=50
    and not exists(select 1 from public.rental_external_payment_actions e where e.payment_charge_id=c.id and e.action_type='refund') limit 1;
  if aid is null or receipt is null then raise exception 'Regression fixture unavailable; do not skip validation.'; end if;

  -- Original root cause: an external receipt can have a historical deposit
  -- portion without a current allocation. It must not create a released total.
  begin
    delete from public.rental_deposit_allocations where holder_rental_id=rid;
    update public.rentals set rental_total=public.rentmect_rental_net_paid_amount(rid)-coalesce(tax_amount,0)-coalesce(service_fee_total,0)-50 where id=rid;
    result:=public.admin_adjust_external_rental_payment(rid,receipt,'refund',null,'ROLLBACK TEST','Regression test only; rollback');
    if (result->'action'->>'deposit_amount_returned')::numeric<>50 then raise exception 'Missing historical receipt classification'; end if;
    if (select deposit_released_amount from public.rentals where id=rid)<>0 then raise exception 'External receipt contaminated current deposit'; end if;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  -- With a Stripe allocation, an external receipt must not release Stripe funds.
  begin
    update public.rentals set rental_total=public.rentmect_rental_net_paid_amount(rid)-coalesce(tax_amount,0)-coalesce(service_fee_total,0)-50 where id=rid;
    result:=public.admin_adjust_external_rental_payment(rid,receipt,'refund',null,'ROLLBACK TEST','Regression test only; rollback');
    if (result->'action'->>'deposit_amount_returned')::numeric<>0 then raise exception 'External receipt attributed a Stripe deposit return'; end if;
    if (select amount_released from public.rental_deposit_allocations where id=aid)<>0 then raise exception 'Stripe allocation modified by external refund'; end if;
    if (select deposit_held_amount from public.rentals where id=rid)<>300 then raise exception 'Stripe deposit reduced by external refund'; end if;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  -- Local allocations are released once, attributed to the full receipt, and
  -- synchronized without adding the same return twice.
  begin
    update public.rental_deposit_allocations set payment_provider='local',stripe_payment_intent_id=null where id=aid;
    update public.rentals set rental_total=public.rentmect_rental_net_paid_amount(rid)-coalesce(tax_amount,0)-coalesce(service_fee_total,0)-50 where id=rid;
    result:=public.admin_adjust_external_rental_payment(rid,receipt,'refund',null,'ROLLBACK TEST','Regression test only; rollback');
    if (select amount_released from public.rental_deposit_allocations where id=aid)<>50 then raise exception 'Local allocation release wrong'; end if;
    if (select external_receipt_refunded_amount from public.rental_deposit_allocations where id=aid)<>50 then raise exception 'Receipt attribution missing'; end if;
    if (select deposit_released_amount from public.rentals where id=rid)<>50 then raise exception 'Local summary double counted'; end if;
    begin
      perform public.admin_adjust_external_rental_payment(rid,receipt,'refund',null,'ROLLBACK TEST','Regression test only; rollback');
      raise exception 'Duplicate external refund accepted';
    exception when others then
      get stacked diagnostics msg=message_text;
      if msg not like '%already refunded%' then raise; end if;
    end;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  begin
    update public.rental_deposit_allocations set amount_released=amount_held,status='released',refund_id='re_regression_only' where id=aid;
    if (select deposit_released_amount from public.rentals where id=rid)<>300 then raise exception 'Allocation did not synchronize summary'; end if;
    select refund_completed_at into stamp from public.rental_deposit_allocations where id=aid;
    if stamp is null then raise exception 'Missing immutable refund timestamp'; end if;
    update public.rental_deposit_allocations set updated_at=now()+interval '1 day' where id=aid;
    if (select refund_completed_at from public.rental_deposit_allocations where id=aid) is distinct from stamp then raise exception 'Unrelated edit changed refund date'; end if;
    update public.rental_deposit_allocations set status='release_pending',amount_released=0 where id=aid;
    if (select status from public.rental_deposit_allocations where id=aid)<>'released' then raise exception 'Late webhook reversed completed refund'; end if;
    select count(*) into n from public.rental_deposit_allocations where source_rental_id=rid;
    perform public.ensure_rental_deposit_allocation(rid);
    if (select count(*) from public.rental_deposit_allocations where source_rental_id=rid)<>n then raise exception 'Released capture created another deposit'; end if;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  begin
    select stripe_payment_intent_id into payment_intent from public.rental_deposit_allocations where id=aid;
    result:=public.apply_stripe_deposit_refund(rid,aid,'re_atomic_regression',payment_intent,'succeeded',300,null);
    if result->>'status'<>'released' then raise exception 'Atomic refund not marked released'; end if;
    if (select deposit_held_amount from public.rentals where id=rid)<>0
      or (select deposit_released_amount from public.rentals where id=rid)<>300
      or (select deposit_status from public.rentals where id=rid)<>'released' then raise exception 'Atomic summary inconsistent'; end if;
    select deposit_released_at into stamp from public.rentals where id=rid;
    perform public.apply_stripe_deposit_refund(rid,aid,'re_atomic_regression',payment_intent,'pending',300,null);
    if (select deposit_status from public.rentals where id=rid)<>'released' then raise exception 'Late webhook reversed rental status'; end if;
    if (select deposit_released_at from public.rentals where id=rid) is distinct from stamp then raise exception 'Replay moved completed date'; end if;
    begin
      perform public.apply_stripe_deposit_refund(rid,aid,'re_atomic_regression','pi_wrong','succeeded',300,null);
      raise exception 'Wrong payment source accepted';
    exception when others then
      get stacked diagnostics msg=message_text;
      if msg not like '%does not match the deposit payment source%' then raise; end if;
    end;
    if has_function_privilege('authenticated','public.apply_stripe_deposit_refund(uuid,uuid,text,text,text,numeric,text)','EXECUTE') then raise exception 'Untrusted refund settlement allowed'; end if;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  begin
    select r.id,r.deposit_released_amount into completed_id,previous_released
      from public.rentals r where r.status='completed' and r.deposit_status='released'
        and public.rentmect_deposit_chain_release_blockers(r.id)='[]'::jsonb
        and exists(select 1 from public.rental_deposit_allocations where holder_rental_id=r.id and payment_provider='stripe') limit 1;
    if completed_id is null then raise exception 'Completed release fixture unavailable'; end if;
    insert into public.rental_deposit_allocations(holder_rental_id,source_rental_id,source_kind,payment_provider,amount_held)
      values(completed_id,completed_id,'local_payment','local',50) returning id into new_local_id;
    update public.rentals set deposit_status='held',deposit_held_amount=50 where id=completed_id;
    perform public.admin_record_local_deposit_release(completed_id);
    if (select payment_provider from public.rental_deposit_allocations where id=new_local_id)<>'local' then raise exception 'New local receipt incorrectly relinked to an old Stripe capture'; end if;
    if (select deposit_released_amount from public.rentals where id=completed_id)<>previous_released+50 then raise exception 'Direct local return double counted'; end if;
    set constraints all immediate;
    raise exception using errcode='Z0001',message='rollback fixture';
  exception when sqlstate 'Z0001' then null; end;

  set constraints all immediate;
  begin
    update public.rentals set deposit_released_amount=282.04 where id=rid;
    raise exception 'Bad deposit summary was accepted';
  exception when others then
    get stacked diagnostics msg=message_text;
    if msg not like '%must match recorded deposit allocations%' then raise; end if;
  end;
  begin
    update public.rental_deposit_allocations set amount_released=301 where id=aid;
    raise exception 'Over-release was accepted';
  exception when check_violation then null; end;
end;
$$;
select 'PASS: historical external receipt, Stripe isolation, local attribution, duplicate refund, allocation synchronization, immutable dates, stale webhook, capture reuse, atomic settlement, webhook replay, source matching, service-only access, direct local return, commit guard, over-release guard' as validation;
rollback;
