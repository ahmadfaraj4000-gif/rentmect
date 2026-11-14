\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

do $$ declare rid uuid; car uuid; other uuid; q jsonb; before_count integer; returned rentals; start_at timestamptz; end_at timestamptz; begin
 rid:=pg_temp.account_fixture();select vehicle_id into car from rentals where id=rid;
 -- An active car is unavailable even before its due date and for future searches.
 assert rentmect_requires_physical_return_lock('active',current_date+3,'9:00 AM');
 assert not rentmect_is_rental_overdue('active',current_date+3,'9:00 AM');
 assert exists(select 1 from rentmect_vehicle_conflicts(car,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 assert not exists(select 1 from rentmect_vehicle_conflicts(car,now()+interval '20 days',now()+interval '21 days',rid) where kind='physical_return');
 select count(*) into before_count from rental_charge_items where source_type='late_return';
 assert rentmect_stage_late_return_charges(now()+interval '100 days')=0;
 perform reconcile_overdue_rentals();
 assert (select count(*)=before_count from rental_charge_items where source_type='late_return');
 begin update rentals set status='cancelled' where id=rid;raise exception 'Cancellation released occupied vehicle';
 exception when others then assert sqlerrm like 'This vehicle is still out.%',sqlerrm;end;
 begin update rentals set status='completed' where id=rid;raise exception 'Uninspected completion accepted';
 exception when others then assert sqlerrm like '%return inspection%',sqlerrm;end;
 -- Customer return initiation does not unlock inventory.
 update rentals set status='return_initiated' where id=rid;
 assert exists(select 1 from rentmect_vehicle_conflicts(car,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 returned:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,false,'release',null,'available',false,null);
 assert returned.status='completed' and returned.inspection_completed_at is not null;
 assert not exists(select 1 from rentmect_vehicle_conflicts(car,now(),now()+interval '1 day')),'Return must release without any buffer';
 -- Exact end/start boundaries: no padding before or after reservations.
 rid:=pg_temp.account_fixture(); select vehicle_id into car from rentals where id=rid;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='documents_needed',starting_mileage=null,agreement_signed=false,pickup_date=current_date+10,return_date=current_date+11 where id=rid;
 perform set_config('session_replication_role','origin',true);
 start_at:=rentmect_rental_timestamp(current_date+10,'9:00 AM') at time zone 'America/New_York';
 end_at:=rentmect_rental_timestamp(current_date+11,'9:00 AM') at time zone 'America/New_York';
 assert not exists(select 1 from rentmect_vehicle_conflicts(car,start_at-interval '1 day',start_at));
 assert not exists(select 1 from rentmect_vehicle_conflicts(car,end_at,end_at+interval '1 day'));
 assert exists(select 1 from rentmect_vehicle_conflicts(car,end_at-interval '1 second',end_at+interval '1 day'));
 -- Return preserves a separate maintenance restriction.
 rid:=pg_temp.account_fixture();select vehicle_id into car from rentals where id=rid;
 update vehicles set status='maintenance' where id=car;
 returned:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,false,'release',null,'available',false,null);
 assert (select status='maintenance' from vehicles where id=car);
 assert exists(select 1 from rentmect_vehicle_conflicts(car,now(),now()+interval '1 day') where kind='vehicle');
 raise notice 'PASS: possession, no grace, no automatic assessments, inspected return, exact boundaries, maintenance preserved';
end $$;
do $$ declare rid uuid; car uuid; replacement uuid; occupied uuid; q jsonb; changed jsonb; key uuid; n integer; begin
 rid:=pg_temp.account_fixture();select vehicle_id into car from rentals where id=rid;
 -- Extending this rental ignores its own possession lock but never removes it.
 q:=admin_preview_rental_extension(rid,current_date+3,'9:00 AM',69,'Customer explicitly agreed to added days');
 changed:=admin_apply_rental_extension(rid,current_date+3,'9:00 AM',69,'Customer explicitly agreed to added days',gen_random_uuid(),q->>'revision');
 assert (select status='active' from rentals where id=rid);
 assert exists(select 1 from rentmect_vehicle_conflicts(car,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 assert not exists(select 1 from rental_charge_items where rental_id=rid and source_type='late_return');
 -- Concurrent-style checkout attempts use the database guard, not only the picker.
 begin
  insert into pending_bookings(vehicle_id,status,pickup_date,pickup_time,return_date,return_time,expires_at)
  values(car,'pending',current_date+20,'9:00 AM',current_date+21,'9:00 AM',now()+interval '10 minutes');
  raise exception 'Future checkout accepted for occupied car';
 exception when others then assert sqlerrm like '%physical return%',sqlerrm;end;
 occupied:=pg_temp.account_fixture();select vehicle_id into replacement from rentals where id=occupied;
 begin
  perform admin_preview_vehicle_swap(rid,replacement,now()-interval '1 minute','emergency','Admin confirmed actual handover',null,1100,1000);
  raise exception 'Swap accepted an occupied replacement';
 exception when others then assert sqlerrm like '%physical return%' or sqlerrm like '%still with%',sqlerrm;end;
 assert (select vehicle_id=car from rentals where id=rid);
 insert into vehicles(name,daily_rate,security_deposit,status,is_active,published,current_mileage)
 values('Synthetic available replacement',69,300,'available',true,false,0) returning id into replacement;
 q:=admin_preview_vehicle_swap(rid,replacement,now()-interval '1 minute','maintenance','Admin confirmed actual handover',null,1100,0);
 key:=gen_random_uuid();
 changed:=admin_apply_vehicle_swap(rid,replacement,now()-interval '1 minute','maintenance','Admin confirmed actual handover',null,key,q->>'revision',1100,0);
 assert (select vehicle_id=replacement from rentals where id=rid);
 assert not exists(select 1 from rentmect_vehicle_conflicts(car,now(),now()+interval '1 day') where kind in ('physical_return','reservation'));
 assert exists(select 1 from rentmect_vehicle_conflicts(car,now(),now()+interval '1 day') where kind='vehicle');
 assert exists(select 1 from rentmect_vehicle_conflicts(replacement,now()+interval '20 days',now()+interval '21 days') where kind='physical_return');
 assert exists(select 1 from rental_audit_events where rental_id=rid and event_type='admin_swap_physical_handover');
 select count(*) into n from rental_vehicle_swaps where rental_id=rid;
 changed:=admin_apply_vehicle_swap(rid,replacement,now()-interval '1 minute','maintenance','Admin confirmed actual handover',null,key,q->>'revision',1100,0);
 assert (select count(*)=n from rental_vehicle_swaps where rental_id=rid),'Swap retries must be idempotent';
 raise notice 'PASS: own-rental extension, future checkout denial, occupied swap rejection, maintenance swap, possession transfer, idempotency';
end $$;
rollback;
