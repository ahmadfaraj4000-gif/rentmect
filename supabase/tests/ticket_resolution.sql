-- Run only against an isolated database; all synthetic records roll back.
\set ON_ERROR_STOP on
begin;
-- Schema-only local restores omit Storage service grants; mirror its API role access.
grant usage on schema storage to authenticated;
grant select,insert on storage.objects to authenticated;
grant select on public.profiles,public.rentals to authenticated;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/ticket_account_fixture.sql

create function pg_temp.ticket_fixture() returns jsonb language plpgsql as $$declare rid uuid; car uuid; begin
 rid:=pg_temp.ticket_account_fixture();
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_date='2026-10-01',return_date='2026-10-05',status='completed',inspection_completed_at='2026-10-05T13:00:00Z' where id=rid returning vehicle_id into car;
 update vehicles set name='Synthetic ticket Audi #TEST',plate_number='TEST3210',plate_state='CT' where id=car;
 update rental_vehicle_assignments set assigned_from='2026-10-01T13:00:00Z',assigned_until='2026-10-05T13:00:00Z' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 return jsonb_build_object('rental',rid,'vehicle',car);
end$$;
create function pg_temp.ticket_data(car uuid,number text default gen_random_uuid()::text) returns jsonb language sql as $$
 select jsonb_build_object('agency','Synthetic New Britain','ticket_number',number,'vehicle_id',car,'violation_date','2026-10-03','violation_time','19:55:19','timezone','America/New_York','issue_date','2026-10-08','amount','50');
$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); d jsonb; saved jsonb; matches jsonb; c jsonb; before_charges bigint; before_events bigint; snapshot jsonb; begin
 select count(*) into before_charges from rental_charge_items;
 select count(*) into before_events from rental_audit_events;
 select to_jsonb(r) into snapshot from rentals r where id=(f->>'rental')::uuid;
 d:=pg_temp.ticket_data((f->>'vehicle')::uuid);
 saved:=admin_ticket_save(tid,null,d);
 assert (saved->'case'->>'occurred_at')::timestamptz='2026-10-03T23:55:19Z'::timestamptz;
 assert saved->'case'->>'issue_date'='2026-10-08';
 assert (admin_ticket_save(tid,null,d)->>'duplicate')::boolean;
 assert (admin_ticket_save(gen_random_uuid(),null,d||jsonb_build_object('agency','  SYNTHETIC   NEW BRITAIN '))->>'duplicate')::boolean;
 matches:=admin_ticket_candidates(tid);
 assert jsonb_array_length(matches->'candidates')=1,matches::text;
 assert matches->'candidates'->0->>'id'=f->>'rental';
 c:=admin_ticket_action(tid,1,'confirm',jsonb_build_object('rental_id',f->>'rental','token',matches->>'token','note','Verified the agreement and original possession records'));
 assert c->>'status'='matched';
 begin perform admin_ticket_save(tid,1,d); raise exception 'Stale update accepted'; exception when serialization_failure then null; end;
 begin perform admin_ticket_action(tid,2,'resolve','{"outcome":"paid_to_agency","note":"Agency payment verified"}'); raise exception 'Payer omission accepted'; exception when others then if SQLERRM not like '%who paid%' then raise; end if; end;
 c:=admin_ticket_action(tid,2,'resolve','{"outcome":"paid_to_agency","paid_by":"Business","note":"Agency receipt verified; reimbursement not collected"}');
 assert c->>'status'='resolved' and c->>'paid_by'='Business';
 begin perform admin_ticket_save(tid,3,d); raise exception 'Resolved ticket edited'; exception when others then if SQLERRM not like '%Reopen%' then raise; end if; end;
 c:=admin_ticket_action(tid,3,'reopen','{"note":"Need to review a correction"}');
 assert c->>'status'='matched' and c->>'outcome' is null;
 saved:=admin_ticket_save(tid,4,d||'{"violation_time":"20:00:00"}');
 assert saved->'case'->>'status'='needs_review' and saved->'case'->>'rental_id' is null;
 assert (select count(*) from rental_charge_items)=before_charges;
 assert (select count(*) from rental_audit_events)=before_events;
 assert (select to_jsonb(r) from rentals r where id=(f->>'rental')::uuid)=snapshot;
 assert (select count(*) from ticket_activity where ticket_id=tid)=5;
 raise notice 'PASS save, duplicate normalization, historical match, optimistic concurrency, resolution/reopen, evidence reset, no rental or financial side effects';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); d jsonb; m jsonb; car2 uuid; rid uuid:=(f->>'rental')::uuid; begin
 perform set_config('session_replication_role','replica',true);
 insert into vehicles(name,daily_rate,security_deposit,status,is_active,published) values('Synthetic swap car',69,300,'available',true,false) returning id into car2;
 update rental_vehicle_assignments set assigned_until='2026-10-03T23:55:19Z' where rental_id=rid;
 insert into rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source) values(rid,car2,'2026-10-03T23:55:19Z','2026-10-05T13:00:00Z','active_swap');
 update rentals set vehicle_id=car2 where id=rid;
 perform set_config('session_replication_role','origin',true);
 d:=pg_temp.ticket_data((f->>'vehicle')::uuid);
 perform admin_ticket_save(tid,null,d);
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=0,'Old vehicle included at exact swap boundary';
 perform admin_ticket_save(tid,1,d||jsonb_build_object('vehicle_id',car2));
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=1,'New vehicle missing at swap boundary';
 perform admin_ticket_save(tid,2,d||jsonb_build_object('vehicle_id',car2,'violation_time',''));
 m:=admin_ticket_candidates(tid); assert (m->>'time_unknown')::boolean;
 begin perform admin_ticket_action(tid,3,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token')); raise exception 'Unknown-time match accepted without note';
 exception when others then if SQLERRM not like '%uncertain match%' then raise; end if; end;
 perform admin_ticket_action(tid,3,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token','note','Reviewed original handover and timestamp evidence'));
 raise notice 'PASS swaps, exact exclusive boundaries, whole-day search and required human verification';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); d jsonb; m jsonb; rid uuid:=(f->>'rental')::uuid; begin
 d:=pg_temp.ticket_data((f->>'vehicle')::uuid);
 perform set_config('session_replication_role','replica',true);
 delete from rental_vehicle_assignments where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 perform admin_ticket_save(tid,null,d); m:=admin_ticket_candidates(tid);
 assert (m->'candidates'->0->>'booked_fallback')::boolean;
 begin perform admin_ticket_action(tid,1,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token')); raise exception 'Fallback accepted without review'; exception when others then if SQLERRM not like '%uncertain match%' then raise; end if; end;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='pending',starting_mileage=null where id=rid;
 perform set_config('session_replication_role','origin',true);
 m:=admin_ticket_candidates(tid); assert not (m->'candidates'->0->>'eligible')::boolean;
 begin perform admin_ticket_action(tid,1,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token','note','Reviewed but not started')); raise exception 'Unstarted rental accepted'; exception when others then if SQLERRM not like '%eligible rental%' then raise; end if; end;
 perform set_config('session_replication_role','replica',true);
 update rentals set status='cancelled' where id=rid;
 perform set_config('session_replication_role','origin',true);
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=0;
 raise notice 'PASS missing ledger fallback, unstarted and cancelled exclusions';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); d jsonb; m jsonb; car uuid:=(f->>'vehicle')::uuid; begin
 d:=pg_temp.ticket_data(null)||'{"plate_number":"TEST3210","plate_state":"CT"}';
 perform admin_ticket_save(tid,null,d); m:=admin_ticket_candidates(tid);
 assert jsonb_array_length(m->'candidates')=0,'Current plate became historical proof';
 perform admin_ticket_save(tid,1,d||jsonb_build_object('vehicle_id',car)); m:=admin_ticket_candidates(tid);
 assert (m->>'vehicle_verification_required')::boolean;
 begin perform admin_ticket_action(tid,2,'confirm',jsonb_build_object('rental_id',f->>'rental','token',m->>'token','note','Reviewed renter dates')); raise exception 'Missing plate note accepted'; exception when others then if SQLERRM not like '%vehicle verification note%' then raise; end if; end;
 insert into tollspot_plate_assignments(vehicle_id,tollspot_vehicle_id,tollspot_license_plate_id,tollspot_assignment_id,plate_number,plate_state,assigned_at,removed_at)
 values(car,'synthetic','synthetic',gen_random_uuid()::text,'TEST3210','CT','2026-10-01T00:00:00Z','2026-10-06T00:00:00Z');
 begin perform admin_ticket_action(tid,2,'confirm',jsonb_build_object('rental_id',f->>'rental','token',m->>'token')); raise exception 'Stale evidence accepted'; exception when serialization_failure then null; end;
 m:=admin_ticket_candidates(tid); assert not (m->>'vehicle_verification_required')::boolean;
 perform admin_ticket_save(tid,2,d); m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=1;
 raise notice 'PASS time-valid plate history, explicit vehicle review and stale matching evidence';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); d jsonb; begin
 assert cardinality(ticket_time_options('2026-11-01','01:30:00','America/New_York'))=2;
 assert cardinality(ticket_time_options('2026-03-08','02:30:00','America/New_York'))=0;
 d:=pg_temp.ticket_data((f->>'vehicle')::uuid)||'{"violation_date":"2026-11-01","violation_time":"01:30:00"}';
 begin perform admin_ticket_save(gen_random_uuid(),null,d); raise exception 'Fold silently resolved'; exception when others then if SQLERRM not like '%occurrence%' then raise; end if; end;
 perform admin_ticket_save(gen_random_uuid(),null,d||'{"occurred_at":"2026-11-01T06:30:00Z"}');
 begin perform admin_ticket_save(gen_random_uuid(),null,d||jsonb_build_object('ticket_number',gen_random_uuid(),'violation_date','2026-03-08','violation_time','02:30:00')); raise exception 'Gap silently resolved'; exception when others then if SQLERRM not like '%does not exist%' then raise; end if; end;
 raise notice 'PASS DST fold requires explicit instant, DST gap rejected';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); d jsonb; m jsonb; rid uuid:=(f->>'rental')::uuid; other uuid; begin
 d:=pg_temp.ticket_data((f->>'vehicle')::uuid);
 perform admin_ticket_save(tid,null,d);
 perform set_config('session_replication_role','replica',true);
 update rentals set inspection_completed_at='2026-10-03T23:00:00Z' where id=rid;
 perform set_config('session_replication_role','origin',true);
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=0,'Matched after early return inspection';
 perform set_config('session_replication_role','replica',true);
 update rentals set status='overdue',inspection_completed_at=null,return_date='2026-10-02' where id=rid;
 update rental_vehicle_assignments set assigned_until='2026-10-02T13:00:00Z' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=1,'Missed overdue possession';
 other:=pg_temp.ticket_account_fixture();
 perform set_config('session_replication_role','replica',true);
 update rentals set vehicle_id=(f->>'vehicle')::uuid,pickup_date='2026-10-03',return_date='2026-10-07' where id=other;
 update rental_vehicle_assignments set vehicle_id=(f->>'vehicle')::uuid,assigned_from='2026-10-03T13:00:00Z',assigned_until='2026-10-07T13:00:00Z' where rental_id=other;
 perform set_config('session_replication_role','origin',true);
 m:=admin_ticket_candidates(tid); assert jsonb_array_length(m->'candidates')=2,'Overlapping rental hidden';
 begin perform admin_ticket_action(tid,1,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token')); raise exception 'Overlap confirmed without note'; exception when others then if SQLERRM not like '%uncertain match%' then raise; end if; end;
 raise notice 'PASS early returns, overdue possession and overlapping rental review';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid; d jsonb; result jsonb; label text:='Synthetic pagination '||gen_random_uuid(); today date:=(now() at time zone 'America/New_York')::date; begin
 for i in 1..30 loop
  tid:=gen_random_uuid();
  d:=pg_temp.ticket_data((f->>'vehicle')::uuid)||jsonb_build_object('agency',label,'payment_deadline',today+i-2);
  perform admin_ticket_save(tid,null,d);
 end loop;
 result:=admin_ticket_list(label); assert (result->>'total')::int=30 and jsonb_array_length(result->'rows')=25;
 assert result->'rows'->0->>'next_deadline'=(today-1)::text;
 result:=admin_ticket_list(label,'unresolved',null,'',25); assert jsonb_array_length(result->'rows')=5;
 result:=admin_ticket_list(label,'unresolved',null,'overdue'); assert (result->>'total')::int=1;
 result:=admin_ticket_list(label,'unresolved',null,'week'); assert (result->>'total')::int=8;
 raise notice 'PASS server pagination, nearest deadline sorting, overdue and seven-day filters';
end$$;

do $$declare f jsonb:=pg_temp.ticket_fixture(); tid uuid:=gen_random_uuid(); aid uuid:=gen_random_uuid(); a jsonb; begin
 perform admin_ticket_save(tid,null,pg_temp.ticket_data((f->>'vehicle')::uuid));
 a:=admin_ticket_attachment(tid,aid,'prepare','{"file_name":"synthetic.heic","mime_type":"image/heic","size_bytes":100}');
 begin perform admin_ticket_attachment(tid,aid,'complete'); raise exception 'Missing object accepted'; exception when others then if SQLERRM not like '%incomplete%' then raise; end if; end;
 insert into storage.objects(bucket_id,name,metadata) values('ticket-evidence',a->>'object_path','{"size":100,"mimetype":"image/heic"}');
 perform admin_ticket_attachment(tid,aid,'complete'); perform admin_ticket_attachment(tid,aid,'complete');
 assert (select count(*) from ticket_activity where ticket_id=tid and action='attachment_added')=1;
 perform admin_ticket_attachment(tid,aid,'remove');
 assert (select removed_at is not null from ticket_attachments where id=aid);
 begin perform admin_ticket_attachment(tid,gen_random_uuid(),'prepare','{"file_name":"big.pdf","mime_type":"application/pdf","size_bytes":20971521}'); raise exception 'Oversize attachment accepted'; exception when check_violation then null; end;
 raise notice 'PASS attachment metadata, completion validation, replay and removal audit';
end$$;

-- Use real role switching to exercise grants and RLS, not merely helper checks.
select pg_temp.ticket_fixture();
set local role authenticated;
select public.admin_ticket_list();
reset role;
set local session_replication_role=replica;
update profiles set staff_role='employee' where id='11111111-1111-4111-8111-111111111111';
set local session_replication_role=origin;
delete from staff_permission_overrides where user_id='11111111-1111-4111-8111-111111111111' and permission_key in ('tab.tickets','ticket.manage');
set local role authenticated;
do $$begin
 assert (select count(*) from ticket_cases)=0;
 assert (select count(*) from storage.objects where bucket_id='ticket-evidence')=0;
 begin perform admin_ticket_list(); raise exception 'Employee read allowed'; exception when insufficient_privilege then null; end;
 begin perform admin_ticket_save(gen_random_uuid(),null,'{}'); raise exception 'Employee write allowed'; exception when insufficient_privilege then null; end;
end$$;
reset role;
update employee_permissions set enabled=true where permission_key='tab.tickets';
set local role authenticated;
do $$begin
 assert (select count(*) from ticket_cases)>0;
 perform admin_ticket_list();
 begin perform admin_ticket_save(gen_random_uuid(),null,'{}'); raise exception 'Read-only employee write allowed'; exception when insufficient_privilege then null; end;
 begin update ticket_cases set notes='bypass'; raise exception 'Direct write allowed'; exception when insufficient_privilege then null; end;
end$$;
reset role;
set request.jwt.claim.sub='22222222-2222-4222-8222-222222222222';
set local role authenticated;
do $$begin
 assert (select count(*) from ticket_cases)=0;
 begin perform admin_ticket_list(); raise exception 'Customer read allowed'; exception when insufficient_privilege then null; end;
end$$;
reset role;
rollback;
