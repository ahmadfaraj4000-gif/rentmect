-- ISOLATED DATABASE ONLY. Seed synthetic states; exercise the public decision.
begin;
\ir fixtures/account_fixture.sql
create function pg_temp.assert_availability(car uuid, pickup date, pickup_time text, expected boolean, reason_fragment text)
returns void language plpgsql as $$
declare decision record; canonical boolean;
begin
 select * into strict decision from get_admin_calendar_fleet_availability(pickup,pickup_time,pickup+2,pickup_time) where vehicle_id=car;
 select not exists(select 1 from rentmect_vehicle_conflicts(car,
   rentmect_rental_timestamp(pickup,pickup_time) at time zone 'America/New_York',
   rentmect_rental_timestamp(pickup+2,pickup_time) at time zone 'America/New_York')) into canonical;
 if decision.available is distinct from expected or decision.available is distinct from canonical
   or position(reason_fragment in decision.reason)=0 then
   raise exception 'Availability differs from the booking guard or expected reason: %',row_to_json(decision);
 end if;
end $$;
do $$ declare rid uuid; car uuid; hold_id uuid; block_id uuid;
begin
 rid:=pg_temp.account_fixture();
 select vehicle_id into car from rentals where id=rid;
 -- Physical-return locks must block future dates even without an overlap.
 perform set_config('session_replication_role','replica',true);
 update rentals set return_date=current_date-1 where id=rid;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',false,'physical return');
 -- A future approved reservation enforces both the overlap and turnaround.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='approved',pickup_date=current_date+7,return_date=current_date+8 where id=rid;
 update rental_vehicle_assignments set assigned_from=rentmect_rental_timestamp(current_date+7,'9:00 AM') at time zone 'America/New_York',
   assigned_until=rentmect_rental_timestamp(current_date+8,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',false,'turnaround');
 perform pg_temp.assert_availability(car,current_date+8,'11:59 AM',false,'turnaround');
 perform pg_temp.assert_availability(car,current_date+8,'12:00 PM',true,'Available');
 -- Cancellation releases the reservation and assignment calendar.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='cancelled' where id=rid;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',true,'Available');
 perform set_config('session_replication_role','replica',true);
 insert into pending_bookings(vehicle_id,pickup_date,pickup_time,return_date,return_time,expires_at)
   values(car,current_date+7,'9:00 AM',current_date+8,'9:00 AM',now()+interval '25 minutes') returning id into hold_id;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',false,'checking out');
 perform set_config('session_replication_role','replica',true);
 update pending_bookings set expires_at=now()-interval '1 second' where id=hold_id;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',true,'Available');
 perform set_config('session_replication_role','replica',true);
 insert into vehicle_availability_blocks(vehicle_id,start_date,end_date,label)
   values(car,current_date+7,current_date+9,'Synthetic calendar block') returning id into block_id;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',false,'calendar');
 perform set_config('session_replication_role','replica',true);
 update vehicle_availability_blocks set active=false where id=block_id;
 update vehicles set maintenance_lock_active=true where id=car;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_availability(car,current_date+7,'9:00 AM',false,'unavailable');
 if not has_function_privilege('authenticated','public.get_admin_calendar_fleet_availability(date,text,date,text)','EXECUTE')
   or has_function_privilege('authenticated','public.rentmect_vehicle_conflicts(uuid,timestamptz,timestamptz,uuid,uuid)','EXECUTE') then
   raise exception 'Customer availability permissions changed';
 end if;
end $$;
rollback;
