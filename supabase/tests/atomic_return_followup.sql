\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

do $$ declare rid uuid; uid uuid; car uuid; result rentals; context jsonb; counts integer; begin
 rid:=pg_temp.account_fixture(300,813.67);select user_id,vehicle_id into uid,car from rentals where id=rid;
 context:=jsonb_build_object('issue_type','damage','customer_action','block','photo_paths',jsonb_build_array(uid::text||'/return-damage/'||rid::text||'/synthetic.jpg'));
 begin
  perform admin_inspect_and_complete_rental_return(rid,900,true,true,true,true,'hold','Verified return damage','maintenance',false,context);
  raise exception 'Invalid odometer accepted';
 exception when others then assert sqlerrm like 'Ending mileage cannot%', sqlerrm;end;
 assert not exists(select 1 from vehicle_reports where rental_id=rid);
 assert not exists(select 1 from rental_messages where rental_id=rid);
 assert not exists(select 1 from rental_return_inspections where rental_id=rid);
 assert (select status='active' from rentals where id=rid);
 assert (select customer_status='good' from profiles where id=uid);
 -- Force a downstream profile permission failure after the core return runs.
 -- Configure a synthetic staff role; restore every business trigger before calling the return.
 perform set_config('session_replication_role','replica',true);
 update profiles set staff_role='employee' where id=auth.uid();
 perform set_config('session_replication_role','origin',true);
 insert into employee_permissions(permission_key,label,category,description,enabled) values
 ('communications.send','Send messages','Communications','Synthetic test',false),('rental.return','Return rentals','Rentals','Synthetic test',false),('customer.manage','Manage customers','Customers','Synthetic test',false) on conflict do nothing;
 insert into staff_permission_overrides(user_id,permission_key,enabled) values(auth.uid(),'communications.send',true),(auth.uid(),'rental.return',true),(auth.uid(),'customer.manage',false)
 on conflict(user_id,permission_key) do update set enabled=excluded.enabled;
 begin
  perform admin_inspect_and_complete_rental_return(rid,1100,true,true,true,true,'hold','Verified return damage','maintenance',false,context);
  raise exception 'Missing customer permission accepted';
 exception when others then assert sqlerrm like 'Customer management permission%', sqlerrm;end;
 assert (select status='active' and ending_mileage is null from rentals where id=rid);
 assert not exists(select 1 from vehicle_reports where rental_id=rid);
 assert not exists(select 1 from rental_messages where rental_id=rid);
 assert not exists(select 1 from rental_return_inspections where rental_id=rid);
 -- Configure a synthetic staff role; restore every business trigger before calling the return.
 perform set_config('session_replication_role','replica',true);
 update profiles set staff_role='owner' where id=auth.uid();
 perform set_config('session_replication_role','origin',true);
 result:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,true,'hold','Verified return damage','maintenance',false,context);
 assert result.status='completed' and result.deposit_release_due_at is null;
 assert (select count(*)=1 from vehicle_reports where rental_id=rid);
 assert (select count(*)=1 from rental_messages where rental_id=rid);
 assert (select customer_status='blocked' from profiles where id=uid);
 assert (select status='maintenance' from vehicles where id=car);
 assert rentmect_rental_net_paid_amount(rid)=813.67;
 -- A retry cannot duplicate the case or notice.
 begin
  perform admin_inspect_and_complete_rental_return(rid,1100,true,true,true,true,'hold','Verified return damage','maintenance',false,context);
  raise exception 'Completed return accepted twice';
 exception when others then assert sqlerrm like 'Only an active%', sqlerrm;end;
 assert (select count(*)=1 from vehicle_reports where rental_id=rid);
 assert (select count(*)=1 from rental_messages where rental_id=rid);
 -- A damage-free return ignores a stale/default customer review value.
 rid:=pg_temp.account_fixture(300,813.67);select user_id into uid from rentals where id=rid;
 result:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,false,'release',null,'available',false,'{"customer_action":"review","photo_paths":[]}');
 assert (select customer_status='good' from profiles where id=uid);
 assert not exists(select 1 from vehicle_reports where rental_id=rid);
 assert not exists(select 1 from rental_messages where rental_id=rid);
 -- Evidence cannot be attached to the wrong rental.
 rid:=pg_temp.account_fixture(300,813.67);
 begin
  perform admin_inspect_and_complete_rental_return(rid,1100,true,true,true,true,'hold','Verified return damage','maintenance',false,context);
  raise exception 'Foreign evidence accepted';
 exception when others then assert sqlerrm like 'Return evidence must belong%', sqlerrm;end;
 assert (select status='active' from rentals where id=rid);
 raise notice 'PASS: rejected return and downstream failure roll back all effects; valid return records exactly once; ordinary return does not flag customer';
end $$;
rollback;
