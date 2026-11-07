-- ISOLATED DATABASE ONLY. Synthetic records; all changes roll back.
-- Requires the full public production schema, constraints, and triggers.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temporary table consistency_results(scenario text,result text);
\ir fixtures/account_fixture.sql
do $test$
declare rid uuid; cid uuid; result jsonb; n integer; state text; error_text text;
begin
  -- Reproduces the four live stale-balance accounts without using real receipts.
  rid:=pg_temp.account_fixture();
  perform public.sync_rental_remaining_balance(rid);
  perform public.record_stripe_checkout_payment('evt_fixture_'||rid,'checkout.session.completed','rental',rid,
    'cs_fixture_'||rid,'pi_fixture_'||rid,'cus_fixture',81367,'usd','{}');
  if public.rentmect_rental_net_paid_amount(rid)<>813.67
    or exists(select 1 from rental_charge_items where rental_id=rid and charge_type='rental_amendment'
      and status in ('pending','checkout_open','failed')) then
    raise exception 'Initial receipt left a collectible balance.';
  end if;
  result:=public.record_stripe_checkout_payment('evt_fixture_'||rid,'checkout.session.completed','rental',rid,
    'cs_fixture_'||rid,'pi_fixture_'||rid,'cus_fixture',81367,'usd','{}');
  if result->>'reason'<>'duplicate_event' then raise exception 'Repeated webhook double-counted receipt.'; end if;
  insert into consistency_results values('Initial full receipt retires pending balance; webhook retry is idempotent','passed');

  rid:=pg_temp.account_fixture(0,513.67);
  result:=public.sync_rental_remaining_balance(rid);
  if result->>'payment_status'<>'paid' or not exists(select 1 from rental_step_completions
    where rental_id=rid and step_key='deposit' and completion_source='admin_deposit_waived') then
    raise exception 'Zero-deposit settlement violates live completion-source rules.';
  end if;
  insert into consistency_results values('Zero-deposit paid account settles under live CHECK constraints','passed');

  rid:=pg_temp.account_fixture(300,400);
  perform public.rentmect_initialize_pricing_periods(rid);
  set constraints all immediate;
  set constraints all deferred;
  begin
    update rental_pricing_periods set rental_amount=rental_amount+0.01 where rental_id=rid;
    set constraints all immediate;
    raise exception 'FAIL: invoice/period drift accepted';
  exception when others then
    if sqlerrm<>'Rental invoice must equal its dated rental and tax amounts.' then raise; end if;
  end;
  begin
    update rental_pricing_periods set tax_amount=tax_amount+0.01 where rental_id=rid;
    set constraints all immediate;
    raise exception 'FAIL: tax drift accepted';
  exception when others then
    if sqlerrm<>'Rental invoice must equal its dated rental and tax amounts.' then raise; end if;
  end;
  begin
    update rental_pricing_periods set rental_amount=-0.01 where rental_id=rid;
    raise exception 'FAIL: negative priced period accepted';
  exception when check_violation then null; end;
  insert into consistency_results values('One-cent rental drift, tax drift, and negative periods rejected','passed');

  -- A stale row cannot be claimed for a saved-card or Checkout attempt.
  rid:=pg_temp.account_fixture(300,813.67);
  insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount,status,source_type)
    select id,user_id,'Synthetic stale balance','rental_amendment',500,500,'pending','rental_balance'
    from rentals where id=rid returning id into cid;
  -- The insertion trigger may retire it. Simulate pre-existing damage only in
  -- the fixture; collection runs with all production triggers enabled.
  perform set_config('session_replication_role','replica',true);
  update rental_charge_items set status='pending' where id=cid;
  perform set_config('session_replication_role','origin',true);
  begin
    update rental_charge_items set status='checkout_open',admin_charge_attempts=1 where id=cid;
    raise exception 'FAIL: stale debt collectible';
  exception when others then
    if sqlerrm<>'This collection amount is stale. Refresh the rental balance before taking payment.' then raise; end if;
  end;
  insert into consistency_results values('Settled invoice rejects stale balance collection before card confirmation','passed');

  rid:=pg_temp.account_fixture(300,400);
  result:=public.sync_rental_remaining_balance(rid);
  cid:=(result->>'balance_charge_id')::uuid;
  update rental_charge_items set status='checkout_open',admin_charge_attempts=1 where id=cid;
  if (select total_amount from rental_charge_items where id=cid)<>413.67 then raise exception 'Valid balance blocked.'; end if;
  insert into consistency_results values('Correct partial-payment remainder remains collectible','passed');

  for state in select p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace
    and p.proname in ('record_stripe_checkout_payment','release_extension_calendar_hold',
      'transfer_rental_deposit_allocations','complete_discount_comped_rental','sync_rental_remaining_balance') loop
    if has_function_privilege('anon',state,'execute') or has_function_privilege('authenticated',state,'execute')
      or not has_function_privilege('service_role',state,'execute') then
      raise exception 'Unsafe internal helper access: %',state;
    end if;
  end loop;
  insert into consistency_results values('Internal payment, hold, deposit and settlement helpers restricted to server callers','passed');
end; $test$;
set constraints all immediate;
table consistency_results;
rollback;
