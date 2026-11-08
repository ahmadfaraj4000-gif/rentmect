begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
-- Seed an old completed rental with its forgotten request, then run the real
-- migration again to exercise the data repair and idempotent deployment.
create temporary table cleanup_fixture(rid uuid,eid uuid);
do $$
declare rid uuid; eid uuid;
begin
 rid:=pg_temp.account_fixture();
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',inspection_completed_at=now() where id=rid;
 insert into rental_extension_requests(rental_id,user_id,requested_return_date,status,payment_status,admin_note)
 select id,user_id,current_date+1,'pending','not_due','Preserved original note' from rentals where id=rid returning id into eid;
 perform set_config('session_replication_role','origin',true);
 insert into cleanup_fixture values(rid,eid);
end $$;
create temporary table before_cleanup as select
 (select count(*) from email_outbox) emails,(select count(*) from rental_messages) messages,
 (select count(*) from admin_notification_events) notifications,
 (select to_jsonb(r) from rentals r where id=(select f.rid from cleanup_fixture f)) rental;
\ir ../migrations/20261108201000_retire_unapproved_closed_extensions.sql
\ir ../migrations/20261108201000_retire_unapproved_closed_extensions.sql

do $$
declare rid uuid; pending uuid; payment_attempt uuid; approved uuid; terminal text; scenario text;
begin
 assert (select status='cancelled' and payment_status='not_due' and admin_note like 'Preserved original note%' from rental_extension_requests where id=(select f.eid from cleanup_fixture f));
 assert (select to_jsonb(r) from rentals r where id=(select f.rid from cleanup_fixture f))=(select rental from before_cleanup);
 assert (select count(*) from email_outbox)=(select emails from before_cleanup);
 assert (select count(*) from rental_messages)=(select messages from before_cleanup);
 assert (select count(*) from admin_notification_events)=(select notifications from before_cleanup);
 foreach terminal in array array['completed','cancelled'] loop
  foreach scenario in array array['unapproved','checkout','approved'] loop
   rid:=pg_temp.account_fixture();
   perform set_config('session_replication_role','replica',true);
   insert into rental_extension_requests(rental_id,user_id,requested_return_date,status,payment_status,stripe_checkout_session_id)
   select id,user_id,current_date+1,
    case when scenario='approved' then 'approved_pending_payment' else 'pending' end,
    case when scenario='approved' then 'pending' else 'not_due' end,
    case when scenario='checkout' then 'cs_synthetic_protected' else null end
   from rentals where id=rid returning id into pending;
   perform set_config('session_replication_role','origin',true);
   update rentals set status=terminal,ending_mileage=case when terminal='completed' then 1001 else null end,inspection_completed_at=case when terminal='completed' then now() else null end where id=rid;
   assert (select status from rental_extension_requests where id=pending)=
    case when scenario='unapproved' then 'cancelled' when scenario='approved' then 'approved_pending_payment' else 'pending' end;
  end loop;
 end loop;
end $$;
rollback;
