-- ISOLATED DATABASE ONLY. Exercise the legacy linked-rental exchange with
-- real production triggers; no Stripe or other provider is contacted.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
\ir fixtures/account_fixture.sql
create temporary table continuation_results(scenario text,result text);
do $test$
declare rid uuid; replacement uuid; customer uuid; eid uuid; child uuid; q jsonb;
  tomorrow date:=(now() at time zone 'America/New_York')::date+1;
  provider text; required_deposit numeric; expected_rental numeric; expected_tax numeric;
  expected_receipt numeric; expected_credit numeric; result jsonb;
begin
  foreach provider in array array['local','stripe'] loop
    foreach required_deposit in array array[200::numeric,300::numeric,500::numeric] loop
      rid:=pg_temp.account_fixture(300,813.67);
      perform set_config('session_replication_role','replica',true);
      update rentals set return_date=tomorrow where id=rid;
      update rental_vehicle_assignments set assigned_until=assigned_until+interval '1 day' where rental_id=rid;
      select user_id into customer from rentals where id=rid;
      insert into vehicles(name,daily_rate,security_deposit,status,is_active,published)
        values('Synthetic continuation',69,required_deposit,'available',true,false) returning id into replacement;
      perform set_config('session_replication_role','origin',true);
      perform public.ensure_rental_deposit_allocation(rid);
      insert into rental_extension_requests(rental_id,user_id,request_kind,replacement_vehicle_id,status,payment_status,
        original_return_date,original_return_time,requested_return_date,requested_return_time)
        values(rid,customer,'switch_car_continuation',replacement,'pending','pending',tomorrow,'9:00 AM',tomorrow+7,'9:00 AM') returning id into eid;
      insert into rental_documents(rental_id,user_id,document_type,status,insurance_packet_id,insurance_coverage_type,extension_request_id,file_path)
        values(rid,customer,'insurance','approved',gen_random_uuid(),'combined',eid,'synthetic/insurance.pdf');
      q:=public.admin_preview_extension_rate(eid,49);
      perform public.admin_approve_extension_agreement(eid,49,'Customer approved continuation rental',(q->>'total_due')::numeric);
      select extension_rental_amount,extension_tax_amount,extension_total_amount,deposit_carried_amount
        into expected_rental,expected_tax,expected_receipt,expected_credit from rental_extension_requests where id=eid;
      -- A fleet price change after approval must not reprice the child rental.
      update vehicles set daily_rate=99,security_deposit=700 where id=replacement;
      update rentals set agreement_signed=true,agreement_signed_at=now(),agreement_signature_name='Synthetic' where id=rid;
      if provider='local' then
        select replacement_rental_id into child from public.record_admin_local_rental_extension_payment(eid);
      else
        result:=public.record_stripe_checkout_payment('evt_first_'||eid,'checkout.session.completed','extension',eid,
          'cs_fixture_'||eid,'pi_fixture_'||eid,'cus_fixture',round(expected_receipt*100)::integer,'usd','{}');
        child:=(result->>'replacement_rental_id')::uuid;
        result:=public.record_stripe_checkout_payment('evt_second_'||eid,'payment_intent.succeeded','extension',eid,
          'cs_fixture_'||eid,'pi_fixture_'||eid,'cus_fixture',round(expected_receipt*100)::integer,'usd','{}');
        if result->>'reason'<>'payment_already_recorded' then raise exception 'Second event duplicated extension receipt.'; end if;
      end if;
      if not exists(select 1 from rentals where id=child and rental_total=expected_rental and tax_amount=expected_tax
        and security_deposit=required_deposit and deposit_carried_amount=expected_credit
        and payment_amount_cents=round(expected_receipt*100)::integer and payment_provider=provider and payment_status='paid')
        or public.rentmect_rental_net_paid_amount(child)<>expected_receipt+expected_credit
        or public.rentmect_rental_invoice_total(child)<>expected_receipt+expected_credit
        or (select sum(amount_held-amount_released-amount_applied) from rental_deposit_allocations where holder_rental_id=child)<>required_deposit
        or public.rentmect_rental_invoice_total(rid)<>813.67 or public.rentmect_rental_net_paid_amount(rid)<>813.67 then
        raise exception 'Continuation violated quote, receipt, collateral or parent accounting: % / %',provider,required_deposit;
      end if;
      insert into continuation_results values(provider||' continuation; deposit '||required_deposit||'; frozen rate, receipt, transfer and replay','passed');
    end loop;
  end loop;
end; $test$;
set constraints all immediate;
table continuation_results;
rollback;
