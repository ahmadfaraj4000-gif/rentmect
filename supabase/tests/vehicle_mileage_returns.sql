-- Full production-schema rehearsal; synthetic records only, rolled back.
begin;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
create temp table mileage_results(scenario text);
do $$ declare rid uuid; car uuid; original uuid; q jsonb; result jsonb; request_id uuid; effective timestamptz; r rentals%rowtype; failed boolean; begin
 rid:=pg_temp.account_fixture(300,813.67);
 select vehicle_id into original from rentals where id=rid;
 update rentals set starting_mileage=104244 where id=rid;
 insert into vehicles(name,daily_rate,security_deposit,status,published,current_mileage)
 values('Synthetic lower odometer replacement',69,300,'available',false,69335) returning id into car;
 effective:=rentmect_rental_timestamp(current_date-1,'9:00 AM') at time zone 'America/New_York';
 q:=admin_preview_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null);
 request_id:=gen_random_uuid();
 begin
 perform admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision');
 raise exception 'Missing readings accepted';exception when others then assert sqlerrm like 'Record both%';end;
 begin
 perform admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision',104200,70000);
 raise exception 'Outgoing odometer rollback accepted';exception when others then assert sqlerrm like 'Outgoing mileage%';end;
 begin
 perform admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision',104300,60000);
 raise exception 'Incoming odometer rollback accepted';exception when others then assert sqlerrm like 'Replacement pickup mileage%';end;
 result:=admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision',104300,70000);
 assert (select starting_mileage=70000 and prior_vehicle_miles=56 and mileage_history_complete from rentals where id=rid);
 assert (select current_mileage=104300 from vehicles where id=original);
 assert (select current_mileage=70000 from vehicles where id=car);
 result:=admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision',104300,70000);
 assert (result->>'idempotent_replay')::boolean;
 begin
 perform admin_apply_vehicle_swap(rid,car,effective,'emergency','Verified replacement odometers',null,request_id,q->>'revision',104301,70000);
 raise exception 'Changed mileage replay accepted';exception when others then assert sqlerrm like 'Idempotency key%';end;
 r:=admin_inspect_and_complete_rental_return(rid,70739,true,true,true,false,'release',null,'available',false);
 assert r.status='completed' and r.starting_mileage=70000 and r.ending_mileage=70739 and r.miles_driven=795;
 assert r.deposit_held_amount=300 and rentmect_rental_net_paid_amount(rid)=813.67;
 assert (select current_mileage=70739 and status='available' from vehicles where id=car);
 insert into mileage_results values('swap readings, vehicle baselines, total miles, payment preservation and idempotency');

 rid:=pg_temp.account_fixture(300,813.67);
 begin
 update rentals set status='completed' where id=rid;
 raise exception 'Unaudited missing-mileage closure accepted';exception when others then assert sqlerrm like 'Ending mileage is mandatory%';end;
 begin
 perform admin_inspect_and_complete_rental_return(rid,null,false,true,true,false,'release',null,'available',true);
 raise exception 'Unexplained override accepted';exception when others then assert sqlerrm like 'Explain the missing%';end;
 begin
 perform admin_inspect_and_complete_rental_return(rid,null,false,false,true,false,'release','Odometer display is unreadable','available',true);
 raise exception 'Uninspected override accepted';exception when others then assert sqlerrm like 'Fuel and vehicle condition%';end;
 r:=admin_inspect_and_complete_rental_return(rid,null,false,true,true,false,'release','Odometer display is unreadable','available',true);
 assert r.status='completed' and r.ending_mileage is null and r.miles_driven is null;
 assert exists(select 1 from rental_return_inspections where rental_id=rid and mileage_override and notes='Odometer display is unreadable');
 assert r.deposit_held_amount=300 and r.deposit_release_due_at is not null;
 insert into mileage_results values('audited override closes without fabricated mileage and retains inspection/deposit rules');

 rid:=pg_temp.account_fixture(300,813.67);
 select vehicle_id into original from rentals where id=rid;
 insert into vehicles(name,daily_rate,security_deposit,status,published,current_mileage)
 values('Synthetic historical replacement',69,300,'available',false,69335) returning id into car;
 q:=admin_preview_vehicle_swap(rid,car,effective,'emergency','Historical swap reproduction',null);
 perform admin_apply_vehicle_swap(rid,car,effective,'emergency','Historical swap reproduction',null,gen_random_uuid(),q->>'revision',1100,70000);
 -- Reproduce the old data shape, preserving the original reading but lacking the replacement pickup.
 update rental_vehicle_assignments set starting_mileage=null where rental_id=rid and vehicle_id=car;
 update rentals set starting_mileage=104244 where id=rid;
 assert (admin_rental_detail(rid)->'rental'->>'return_starting_mileage') is null;
 begin
 perform admin_inspect_and_complete_rental_return(rid,70739,true,true,true,false,'release',null,'available',false);
 raise exception 'Missing historical baseline silently accepted';exception when others then assert sqlerrm like 'Explain the missing%';end;
 r:=admin_inspect_and_complete_rental_return(rid,70739,true,true,true,false,'release','Replacement pickup reading was not recorded at historical swap','available',false);
 assert r.status='completed' and r.ending_mileage=70739 and r.starting_mileage is null and r.miles_driven is null;
 assert (select current_mileage=70739 from vehicles where id=car);
 insert into mileage_results values('historical swap records a verified return without inventing distance or comparing two vehicles');

 rid:=pg_temp.account_fixture(300,0);
 r:=admin_inspect_and_complete_rental_return(rid,1100,true,true,true,true,'hold','Verified damage requires repair','maintenance',false);
 assert r.status='completed' and r.deposit_status='held';
 assert rentmect_rental_invoice_total(rid)-rentmect_rental_net_paid_amount(rid)=813.67;
 assert (select status='maintenance' from vehicles where id=r.vehicle_id);
 insert into mileage_results values('damage holds vehicle and deposit; closure preserves unpaid rent');
end $$;
select * from mileage_results;
rollback;
