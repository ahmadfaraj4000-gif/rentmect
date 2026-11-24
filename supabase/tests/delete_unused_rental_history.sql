\set ON_ERROR_STOP on
begin;
\ir fixtures/account_fixture.sql
do $$
declare rid uuid := pg_temp.account_fixture(0,0); cid uuid; vid uuid;
  booked uuid := gen_random_uuid(); owner_id uuid := '11111111-1111-4111-8111-111111111111';
begin
  insert into public.rental_operations_staff values(owner_id,'Fixture operator');
  perform set_config('session_replication_role','replica',true);
  update rentals set status='cancelled', starting_mileage=null, agreement_signed=true where id=rid
    returning user_id,vehicle_id into cid,vid;
  insert into rental_signatures(rental_id,user_id,signature_name) values(rid,cid,'Fixture signer');
  insert into rental_audit_events(rental_id,event_type) values(rid,'agreement_signed_in_office');
  insert into email_outbox(event_key,email_type,rental_id,recipient_email) values(rid::text,'renter_balance_statement',rid,'fixture@example.invalid');
  insert into external_payment_receipts(id,rental_id,actor_id,request,amount_cents,rental_amount_cents,payment_method,received_date,status)
    values(booked,rid,owner_id,'{}',100,100,'card',current_date,'cancelled');
  perform set_config('session_replication_role','origin',true);
  perform set_config('request.jwt.claim.sub',cid::text,true);
  begin
    perform delete_unused_rental(rid,'delete');
    raise exception 'Unauthorized deletion succeeded';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  assert delete_unused_rental(rid)='delete';
  assert exists(select from rental_signatures where rental_id=rid);
  begin
    perform delete_unused_rental(rid,'archive');
    raise exception 'Archive confirmation deleted a rental';
  exception when raise_exception then
    if sqlerrm not like 'Confirm permanent deletion%' then raise; end if;
  end;
  update external_payment_receipts set status='posted' where id=booked;
  begin
    perform delete_unused_rental(rid,'delete');
    raise exception 'Posted receipt deleted';
  exception when raise_exception then
    if sqlerrm not like 'This rental has a payment%' then raise; end if;
  end;
  update external_payment_receipts set status='cancelled' where id=booked;
  assert delete_unused_rental(rid,'delete')='delete';
  assert not exists(select from rentals where id=rid);
  assert not exists(select from rental_signatures where rental_id=rid);
  assert not exists(select from rental_audit_events where rental_id=rid);
  assert not exists(select from external_payment_receipts where rental_id=rid);
  assert not exists(select from email_outbox where rental_id=rid);
  assert exists(select from profiles where id=cid);
  assert exists(select from vehicles where id=vid);
end $$;
rollback;
