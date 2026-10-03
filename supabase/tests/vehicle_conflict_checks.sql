-- Isolated database only. All fixtures roll back; no payment or notification calls.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temporary table availability_results(scenario text,result text);
do $test$
declare actor uuid:='11111111-1111-4111-8111-111111111111'; customer uuid:='22222222-2222-4222-8222-222222222222';
 car uuid; replacement uuid; rid uuid; other uuid; q jsonb; available boolean; result jsonb;
 day date:=(now() at time zone 'America/New_York')::date; swap_at timestamptz:=now()-interval '1 hour';
 until_at timestamptz; blocked boolean;
begin
 perform set_config('session_replication_role','replica',true);
 insert into auth.users(id) values(actor),(customer) on conflict do nothing;
 insert into profiles(id,role,staff_role,date_of_birth) values(actor,'admin','owner','1980-01-01'),(customer,'customer','customer','1980-01-01') on conflict do nothing;
 insert into vehicles(name,daily_rate,security_deposit,status,is_active) values('Availability source',64,300,'rented',true) returning id into car;
 insert into vehicles(name,daily_rate,security_deposit,status,is_active) values('Availability replacement',64,300,'available',true) returning id into replacement;
 insert into rentals(user_id,vehicle_id,status,pickup_date,pickup_time,return_date,return_time,rental_total,tax_amount,security_deposit,payment_status,under_25_markup_percentage)
 values(customer,car,'active',day-2,'9:00 AM',day+1,'9:00 AM',192,12.19,300,'pending',0) returning id into rid;
 insert into rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source)
 values(rid,car,rentmect_rental_timestamp(day-2,'9:00 AM') at time zone 'America/New_York',rentmect_rental_timestamp(day+1,'9:00 AM') at time zone 'America/New_York','initial');
 insert into rentals(vehicle_id,status,pickup_date,pickup_time,return_date,return_time)
 values(replacement,'approved',day+1,'10:00 AM',day+4,'10:00 AM') returning id into other;
 perform set_config('session_replication_role','origin',true);
 until_at:=rentmect_rental_timestamp(day+1,'9:00 AM') at time zone 'America/New_York';
 -- Legacy/fallback booking without an assignment must still block the swap.
 blocked:=false;
 begin perform admin_preview_vehicle_swap(rid,replacement,swap_at,'emergency','Availability regression test',null);
 exception when others then if sqlerrm not like 'Replacement vehicle conflicts%' then raise; end if; blocked:=true; end;
 if not blocked then raise exception 'Swap crossed a future booking turnaround'; end if;
 result:=admin_rental_vehicle_availability(rid,swap_at,until_at,replacement);
 if (result->0->>'available')::boolean or result->0->'next_reservation' is null then raise exception 'Admin visibility disagreed with write guard'; end if;
 select f.available into available from get_admin_calendar_fleet_availability(day,'9:00 AM',day+1,'9:00 AM') f where vehicle_id=replacement;
 if available then raise exception 'Public booking reader advertised the conflicting window'; end if;
 insert into availability_results values('future booking without assignment blocks swap and public/admin availability','passed');
 -- Exactly three hours is allowed, two hours 59 minutes is blocked.
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_time='12:00 PM' where id=other;
 perform set_config('session_replication_role','origin',true);
 perform rentmect_assert_swap_available(rid,replacement,swap_at,until_at);
 if not exists(select 1 from rentmect_vehicle_conflicts(replacement,swap_at,until_at+interval '1 minute',rid)) then raise exception 'Turnaround boundary missing'; end if;
 q:=admin_preview_vehicle_swap(rid,replacement,swap_at,'emergency','Availability regression test',null);
 -- A new reservation between review and confirmation is rechecked at apply.
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_time='10:00 AM' where id=other;
 perform set_config('session_replication_role','origin',true);
 blocked:=false;
 begin perform admin_apply_vehicle_swap(rid,replacement,swap_at,'emergency','Availability regression test',null,gen_random_uuid(),q->>'revision');
 exception when others then if sqlerrm not like 'Replacement vehicle conflicts%' then raise; end if; blocked:=true; end;
 if not blocked then raise exception 'Stale swap confirmation bypassed a new booking'; end if;
 insert into availability_results values('exact turnaround boundary and swap confirmation recheck','passed');
 -- A rental insert must protect the gap before a future reservation too.
 begin
  insert into rentals(vehicle_id,status,pickup_date,pickup_time,return_date,return_time) values(replacement,'pending',day,'9:00 AM',day+1,'9:00 AM');
  raise exception 'FAILED reverse turnaround';
 exception when others then if sqlerrm not like 'Vehicle unavailable:%' then raise; end if; end;
 insert into availability_results values('reservation write protects turnaround before next booking','passed');
 perform set_config('session_replication_role','replica',true);
 update rentals set vehicle_id=car,pickup_date=day+2,pickup_time='12:00 PM',return_date=day+4 where id=other;
 perform set_config('session_replication_role','origin',true);
 blocked:=false;
 begin perform admin_preview_rental_extension(rid,day+2,'10:00 AM',64,'Availability regression extension');
 exception when others then if sqlerrm not like 'Replacement vehicle conflicts%' then raise; end if; blocked:=true; end;
 if not blocked then raise exception 'Extension crossed another reservation'; end if;
 q:=admin_preview_rental_extension(rid,day+2,'9:00 AM',64,'Availability regression extension');
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_time='11:00 AM' where id=other;
 perform set_config('session_replication_role','origin',true);
 blocked:=false;
 begin perform admin_apply_rental_extension(rid,day+2,'9:00 AM',64,'Availability regression extension',gen_random_uuid(),q->>'revision');
 exception when others then if sqlerrm not like 'Replacement vehicle conflicts%' then raise; end if; blocked:=true; end;
 if not blocked then raise exception 'Stale extension confirmation bypassed a new booking'; end if;
 insert into availability_results values('extension rejects future booking and rechecks confirmation','passed');
 -- Maintenance is authoritative even when the vehicle status is stale.
 update vehicles set maintenance_lock_active=true,maintenance_lock_reason='Fixture tire inspection' where id=replacement;
 if not exists(select 1 from rentmect_vehicle_conflicts(replacement,swap_at,until_at,rid) where kind='vehicle') then raise exception 'Maintenance lock ignored'; end if;
 update vehicles set maintenance_lock_active=false where id=replacement;
 insert into vehicle_availability_blocks(vehicle_id,start_date,start_time,end_date,end_time,block_type,active)
 values(replacement,day,'12:00 AM',day+1,'11:59 PM','maintenance',true);
 if not exists(select 1 from rentmect_vehicle_conflicts(replacement,swap_at,until_at,rid) where kind='calendar_block') then raise exception 'Calendar block ignored'; end if;
 delete from vehicle_availability_blocks where vehicle_id=replacement;
 perform set_config('session_replication_role','replica',true);
 insert into pending_bookings(vehicle_id,status,pickup_date,pickup_time,return_date,return_time,expires_at)
 values(replacement,'pending',day,'9:00 AM',day+2,'9:00 AM',now()+interval '10 minutes');
 perform set_config('session_replication_role','origin',true);
 if not exists(select 1 from rentmect_vehicle_conflicts(replacement,swap_at,until_at,rid) where kind='checkout_hold') then raise exception 'Checkout hold ignored'; end if;
 update pending_bookings set expires_at=now()-interval '1 minute' where vehicle_id=replacement;
 if exists(select 1 from rentmect_vehicle_conflicts(replacement,swap_at,until_at,rid)) then raise exception 'Expired hold blocked availability'; end if;
 insert into availability_results values('maintenance locks, calendar blocks, active and expired checkout holds','passed');
 -- An active car cannot actually be released to a second customer even if the
 -- second booking starts after the first scheduled return and buffer.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='ready_for_pickup' where id=other;
 perform set_config('session_replication_role','origin',true);
 begin update rentals set status='active' where id=other; raise exception 'FAILED double release';
 exception when others then if sqlerrm not like 'This vehicle is still with another customer%' then raise; end if; end;
 insert into availability_results values('physical handover blocks a second active rental','passed');
 perform set_config('request.jwt.claim.sub',customer::text,true);
 begin perform admin_rental_vehicle_availability(rid,swap_at,until_at,replacement); raise exception 'FAILED customer permission';
 exception when others then if sqlerrm<>'Rental editing permission is required.' then raise; end if; end;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform admin_rental_vehicle_availability(rid,swap_at,until_at,replacement); raise exception 'FAILED anonymous permission';
 exception when others then if sqlerrm<>'Rental editing permission is required.' then raise; end if; end;
 insert into availability_results values('admin conflict details reject customers and anonymous access','passed');
end; $test$;
select * from availability_results;
rollback;
