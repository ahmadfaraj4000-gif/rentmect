-- Disposable full-schema tests: retained history must not become a false booking.
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

create function pg_temp.assert_conflict(car uuid, starts timestamptz, ends timestamptz, source uuid, expected boolean)
returns void language plpgsql as $$
begin
 assert exists(select 1 from rentmect_vehicle_conflicts(car,starts,ends) where source_id=source)=expected,
   format('Conflict mismatch car=%s source=%s starts=%s expected=%s',car,source,starts,expected);
end $$;

-- Real before-pickup vehicle/date edits must release the discarded reservation,
-- even when its old assignment is retained for audit/toll matching.
do $$
declare rid uuid; car uuid; replacement uuid; q jsonb; day date:=current_date+10;
begin
 rid:=pg_temp.account_fixture();
 select vehicle_id into car from rentals where id=rid;
 insert into vehicles(name,daily_rate,security_deposit,status,is_active,published)
 values('Synthetic pre-pickup replacement',69,300,'available',true,false) returning id into replacement;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='documents_needed',starting_mileage=null,agreement_signed=false,
  pickup_date=day,return_date=day+3,rental_total=207,base_rental_total=207,tax_amount=13.14 where id=rid;
 update rental_vehicle_assignments set assigned_from=rentmect_rental_timestamp(day,'9:00 AM') at time zone 'America/New_York',
  assigned_until=rentmect_rental_timestamp(day+3,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 perform admin_apply_rental_amendment(rid,replacement,day+2,'9:00 AM',day+5,'9:00 AM',69,300,
  'Customer changed vehicle and pickup date','Synthetic fixture',gen_random_uuid());
 assert exists(select 1 from rental_vehicle_assignments where rental_id=rid and vehicle_id=car),'Audit history must remain';
 perform pg_temp.assert_conflict(car,rentmect_rental_timestamp(day+1,'9:00 AM') at time zone 'America/New_York',
  rentmect_rental_timestamp(day+2,'9:00 AM') at time zone 'America/New_York',rid,false);
 perform pg_temp.assert_conflict(replacement,rentmect_rental_timestamp(day+2,'9:00 AM') at time zone 'America/New_York',
  rentmect_rental_timestamp(day+3,'9:00 AM') at time zone 'America/New_York',rid,true);
end $$;

-- Completed rentals protect actual return + 3 hours, not the later original booking.
-- Latest assignment ends may be stale; the saved return/inspection is authoritative.
do $$
declare rid uuid; car uuid; finish timestamptz:=now()-interval '4 hours'; starts timestamptz;
begin
 rid:=pg_temp.account_fixture(); select vehicle_id into car from rentals where id=rid;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',return_date=current_date+14,inspection_completed_at=finish where id=rid;
 update rental_vehicle_assignments set assigned_until=now()+interval '30 days' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_conflict(car,finish+interval '2 hours 59 minutes',finish+interval '2 days',rid,true);
 perform pg_temp.assert_conflict(car,finish+interval '3 hours',finish+interval '2 days',rid,false);
 -- Cancellation ignores even a retained future assignment.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='cancelled',inspection_completed_at=null where id=rid;
 perform set_config('session_replication_role','origin',true);
 perform pg_temp.assert_conflict(car,now(),now()+interval '2 days',rid,false);
end $$;

-- A real started swap blocks each vehicle only over its actual assignment,
-- including exactly three hours after releasing the outgoing vehicle.
do $$
declare rid uuid; old_car uuid; car uuid; q jsonb; switched timestamptz:=now()-interval '4 hours';
begin
 rid:=pg_temp.account_fixture(); select vehicle_id into old_car from rentals where id=rid;
 insert into vehicles(name,daily_rate,security_deposit,status,is_active,published)
 values('Synthetic historical replacement',69,300,'available',true,false) returning id into car;
 perform set_config('session_replication_role','replica',true);
 update rentals set return_date=current_date+3 where id=rid;
 update rental_vehicle_assignments set assigned_until=rentmect_rental_timestamp(current_date+3,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 q:=admin_preview_vehicle_swap(rid,car,switched,'emergency','Synthetic actual vehicle swap',null,1000,0);
 perform admin_apply_vehicle_swap(rid,car,switched,'emergency','Synthetic actual vehicle swap',null,gen_random_uuid(),q->>'revision',1000,0);
 perform pg_temp.assert_conflict(old_car,switched+interval '2 hours 59 minutes',switched+interval '2 days',rid,true);
 perform pg_temp.assert_conflict(old_car,switched+interval '3 hours',switched+interval '2 days',rid,false);
 perform pg_temp.assert_conflict(car,switched-interval '2 days',switched-interval '3 hours',rid,false);
 perform pg_temp.assert_conflict(car,switched-interval '2 days',switched-interval '2 hours 59 minutes',rid,true);
end $$;

-- Edit preview must share swap/booking rules: active holds, physical-return locks,
-- and actual completed-rental turnaround are visible before applying the edit.
do $$
declare rid uuid; car uuid; prior uuid; hold uuid; q jsonb; day date:=current_date+10;
 finish timestamptz;
begin
 rid:=pg_temp.account_fixture(); prior:=pg_temp.account_fixture(); select vehicle_id into car from rentals where id=rid;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='documents_needed',starting_mileage=null,agreement_signed=false,pickup_date=day,return_date=day+1 where id=rid;
 update rental_vehicle_assignments set assigned_from=rentmect_rental_timestamp(day,'9:00 AM') at time zone 'America/New_York',assigned_until=rentmect_rental_timestamp(day+1,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 update rentals set vehicle_id=car,status='completed',inspection_completed_at=now()-interval '1 day' where id=prior;
 update rental_vehicle_assignments set vehicle_id=car where rental_id=prior;
 insert into pending_bookings(vehicle_id,status,pickup_date,pickup_time,return_date,return_time,expires_at)
 values(car,'pending',day+1,'12:00 PM',day+3,'9:00 AM',now()+interval '10 minutes') returning id into hold;
 perform set_config('session_replication_role','origin',true);
 begin
  perform admin_preview_rental_amendment(rid,car,day,'9:00 AM',day+2,'9:00 AM',69,300);
  raise exception 'Edit preview ignored active checkout hold';
 exception when others then if sqlerrm not like '%active checkout hold%' then raise; end if; end;
 update pending_bookings set expires_at=now()-interval '1 minute' where id=hold;
 perform admin_preview_rental_amendment(rid,car,day,'9:00 AM',day+2,'9:00 AM',69,300);
 -- A rented vehicle awaiting inspection blocks even dates beyond its old booked return.
 perform set_config('session_replication_role','replica',true);
 update rentals set status='overdue',inspection_completed_at=null,return_date=current_date-1 where id=prior;
 perform set_config('session_replication_role','origin',true);
 begin
  perform admin_preview_rental_amendment(rid,car,day,'9:00 AM',day+2,'9:00 AM',69,300);
  raise exception 'Edit preview ignored physical return lock';
 exception when others then if sqlerrm not like '%physical return%' then raise; end if; end;
 -- A completed rental's actual three-hour turnaround is still protected by edit.
 finish:=rentmect_rental_timestamp(day,'6:01 AM') at time zone 'America/New_York';
 perform set_config('session_replication_role','replica',true);
 update rentals set status='completed',inspection_completed_at=finish where id=prior;
 perform set_config('session_replication_role','origin',true);
 begin
  perform admin_preview_rental_amendment(rid,car,day,'9:00 AM',day+2,'9:00 AM',69,300);
  raise exception 'Edit preview ignored actual return turnaround';
 exception when others then if sqlerrm not like 'Vehicle schedule conflict:%turnaround%' then raise; end if; end;
 perform set_config('session_replication_role','replica',true);
 update rentals set inspection_completed_at=finish-interval '1 minute' where id=prior;
 perform set_config('session_replication_role','origin',true);
 perform admin_preview_rental_amendment(rid,car,day,'9:00 AM',day+2,'9:00 AM',69,300);
end $$;
-- Actual swap preview and confirmation retain a completed car's return buffer.
do $$
declare rid uuid; prior uuid; car uuid; q jsonb;
begin
 rid:=pg_temp.account_fixture(); prior:=pg_temp.account_fixture();
 select vehicle_id into car from rentals where id=prior;
 perform set_config('session_replication_role','replica',true);
 update rentals set return_date=current_date+3 where id=rid;
 update rental_vehicle_assignments set assigned_until=rentmect_rental_timestamp(current_date+3,'9:00 AM') at time zone 'America/New_York' where rental_id=rid;
 update rentals set status='completed',inspection_completed_at=now()-interval '3 hours',return_date=current_date+14 where id=prior;
 update rental_vehicle_assignments set assigned_until=now()+interval '14 days' where rental_id=prior;
 perform set_config('session_replication_role','origin',true);
 begin
  perform admin_preview_vehicle_swap(rid,car,now()-interval '1 minute','emergency','Synthetic return buffer check',null,1000,0);
  raise exception 'Swap ignored the final turnaround minute';
 exception when others then if sqlerrm not like 'Replacement vehicle conflicts:%' then raise; end if; end;
 q:=admin_preview_vehicle_swap(rid,car,now(),'emergency','Synthetic return buffer check',null,1000,0);
 perform admin_apply_vehicle_swap(rid,car,now(),'emergency','Synthetic return buffer check',null,gen_random_uuid(),q->>'revision',1000,0);
 assert (select vehicle_id=car from rentals where id=rid);
 assert (select status='completed' and inspection_completed_at=now()-interval '3 hours' from rentals where id=prior);
end $$;
set constraints all immediate;
rollback;
