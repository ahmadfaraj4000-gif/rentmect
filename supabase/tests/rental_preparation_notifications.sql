\set ON_ERROR_STOP on
begin;
\ir fixtures/account_fixture.sql
do $$
declare rid uuid:=pg_temp.account_fixture(); customer uuid; packet uuid:=gen_random_uuid();
begin
  select user_id into customer from rentals where id=rid;
  perform set_config('session_replication_role','replica',true);
  update profiles set phone_verified=true,identity_verification_status='verified' where id=customer;
  update rentals set booking_source='customer_portal',payment_status='paid',status='documents_needed',agreement_signed=true where id=rid;
  insert into rental_documents(user_id,rental_id,document_type,status,file_path)
    values(customer,rid,'license','pending_review','synthetic/license');
  insert into rental_documents(user_id,rental_id,document_type,status,file_path,insurance_packet_id,insurance_coverage_type)
    values(customer,rid,'insurance','pending_review','synthetic/liability',packet,'liability');
  perform queue_online_rental_preparation();
  assert not exists(select from admin_notification_events where dedupe_key='online_prep:'||rid);
  insert into rental_documents(user_id,rental_id,document_type,status,file_path,insurance_packet_id,insurance_coverage_type)
    values(customer,rid,'insurance','pending_review','synthetic/collision',packet,'collision');
  perform queue_online_rental_preparation();
  perform queue_online_rental_preparation();
  assert (select count(*) from admin_notification_events where dedupe_key='online_prep:'||rid)=1;
  perform set_config('session_replication_role','origin',true);
  insert into rental_messages(rental_id,user_id,sender_role,message) values(rid,customer,'client','Synthetic test');
  assert exists(select from admin_notification_events where rental_id=rid and event_type='customer_message_received');
end $$;
rollback;
