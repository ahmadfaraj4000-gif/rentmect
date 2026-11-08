-- Disposable full-schema database only. All synthetic records roll back.
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

do $$
declare
  prior uuid; rid uuid; car uuid; q jsonb; result jsonb; blocker_status text;
  prior_snapshot jsonb; block_id uuid;
  day date := current_date+10;
begin
  prior:=pg_temp.account_fixture();
  rid:=pg_temp.account_fixture();
  select vehicle_id into car from rentals where id=prior;
  perform set_config('session_replication_role','replica',true);
  update rentals set status='completed',pickup_date=day-7,return_date=day+1,return_time='5:30 PM',inspection_completed_at=now() where id=prior;
  update rentals set vehicle_id=car,status='documents_needed',starting_mileage=null,
    pickup_date=day,pickup_time='2:30 PM',return_date=day+1,return_time='2:30 PM',
    base_rental_total=74,rental_total=74,tax_amount=4.70,security_deposit=400,agreement_signed=false where id=rid;
  update rental_vehicle_assignments set vehicle_id=car,
    assigned_from=rentmect_rental_timestamp(day,'2:30 PM') at time zone 'America/New_York',
    assigned_until=rentmect_rental_timestamp(day+1,'2:30 PM') at time zone 'America/New_York' where rental_id=rid;
  perform set_config('session_replication_role','origin',true);

  -- Reproduces Alice's two-day edit and deposit change over a completed booking.
  q:=admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
  assert (q#>>'{new,return_date}')::date=day+2;
  assert q#>>'{new,return_time}'='5:00 PM';
  assert (q#>>'{new,security_deposit}')::numeric=300;

  -- The same overlapping dates still block every open rental state.
  foreach blocker_status in array array['pending','documents_needed','approved','active','overdue','return_initiated'] loop
    perform set_config('session_replication_role','replica',true);
    update rentals set status=blocker_status,inspection_completed_at=null where id=prior;
    perform set_config('session_replication_role','origin',true);
    begin
      perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
      raise exception 'Open rental conflict was accepted: %',blocker_status;
    exception when others then
      if sqlerrm <> 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.'
        and sqlerrm <> 'Vehicle schedule conflict: awaiting physical return and inspection.' then raise; end if;
    end;
  end loop;

  -- Protect the full turnaround after a previous reservation, including its final minute.
  perform set_config('session_replication_role','replica',true);
  update rentals set status='approved',return_date=day,return_time='11:31 AM' where id=prior;
  perform set_config('session_replication_role','origin',true);
  begin
    perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
    raise exception 'Previous turnaround was ignored';
  exception when others then
    if sqlerrm <> 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.' then raise; end if;
  end;
  perform set_config('session_replication_role','replica',true);
  update rentals set return_time='11:30 AM' where id=prior;
  perform set_config('session_replication_role','origin',true);
  perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);

  -- The edited rental also needs three hours before the next pickup.
  perform set_config('session_replication_role','replica',true);
  update rentals set pickup_date=day+2,pickup_time='7:59 PM',return_date=day+3,return_time='5:00 PM' where id=prior;
  perform set_config('session_replication_role','origin',true);
  begin
    perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
    raise exception 'Next turnaround was ignored';
  exception when others then
    if sqlerrm <> 'Vehicle schedule conflict: another rental or its three-hour turnaround occupies this time.' then raise; end if;
  end;
  perform set_config('session_replication_role','replica',true);
  update rentals set pickup_time='8:00 PM' where id=prior;
  perform set_config('session_replication_role','origin',true);
  perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);

  -- Cancellation remains nonblocking; restore the completed-overlap incident for apply.
  perform set_config('session_replication_role','replica',true);
  update rentals set status='cancelled',pickup_date=day-7,return_date=day+1,return_time='5:30 PM' where id=prior;
  perform set_config('session_replication_role','origin',true);
  perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
  perform set_config('session_replication_role','replica',true);
  update rentals set status='completed',inspection_completed_at=now() where id=prior;
  perform set_config('session_replication_role','origin',true);
  insert into vehicle_availability_blocks(vehicle_id,start_date,end_date,start_time,end_time,label)
    values(car,day+1,day+2,'9:00 AM','9:00 AM','Synthetic amendment block') returning id into block_id;
  begin
    perform admin_preview_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300);
    raise exception 'Calendar block was ignored';
  exception when others then
    if sqlerrm <> 'Vehicle schedule conflict: the admin calendar blocks this time.' then raise; end if;
  end;
  update vehicle_availability_blocks set active=false where id=block_id;
  select to_jsonb(r) into prior_snapshot from rentals r where id=prior;
  result:=admin_apply_rental_amendment(rid,car,day,'2:30 PM',day+2,'5:00 PM',74,300,
    'Synthetic completed rental conflict regression','Synthetic edit',gen_random_uuid());
  assert (select return_date=day+2 and return_time='5:00 PM' and security_deposit=300 from rentals where id=rid);
  assert (select to_jsonb(r) from rentals r where id=prior)=prior_snapshot,'Completed rental history changed';
end $$;
set constraints all immediate;
rollback;
