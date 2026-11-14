\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
-- Synthetic combinations, rolled back: statuses, locks, stale extensions,
-- deposit routing, exact pages, counts, and Realtime membership agree.
do $$
declare rid uuid; car uuid; uid uuid; st text; locked boolean; f text; a jsonb; b jsonb; expected boolean;
 terminal boolean; out_car boolean; today date:=(now() at time zone 'America/New_York')::date;
 ids uuid[]; count_rows integer; page jsonb; offs integer;
begin
 foreach st in array array['documents_needed','ready_for_pickup','approved','active','rented','overdue','return_initiated','completed','cancelled'] loop
 foreach locked in array array[false,true] loop
  rid:=pg_temp.account_fixture(300,813.67);
  select vehicle_id,user_id into car,uid from rentals where id=rid;
  perform set_config('session_replication_role','replica',true);
  update profiles set full_name='Filter matrix',phone_verified=true,identity_verification_status='verified' where id=uid;
  update vehicles set name='FILTER_MATRIX_'||rid,status='available',maintenance_lock_active=locked where id=car;
  update rentals set status=st,return_date=today,return_time='11:59 PM',ending_mileage=case when st='completed' then 1200 else null end,inspection_completed_at=case when st='completed' then now() else null end where id=rid;
  insert into rental_documents(rental_id,user_id,document_type,status,file_path,insurance_packet_id,insurance_coverage_type) values(rid,uid,'license','approved','synthetic',null,null),(rid,uid,'insurance','approved','synthetic',gen_random_uuid(),'combined');
  insert into rental_extension_requests(rental_id,user_id,requested_return_date,status) values(rid,uid,today+1,'pending');
  perform set_config('session_replication_role','origin',true);
  terminal:=st in ('completed','cancelled');out_car:=st in ('active','rented','overdue','return_initiated');
  foreach f in array array['needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive','deposit_review'] loop
   expected:=case f when 'needs_action' then not terminal -- open extension
    when 'ready_pickup' then not terminal and not out_car and not locked
    when 'cars_out' then out_car when 'returns_today' then out_car
    when 'extensions' then not terminal when 'maintenance' then not terminal and locked
    when 'all' then not terminal when 'archive' then st='cancelled' when 'deposit_review' then st='completed' end;
   a:=admin_rental_list(f,'FILTER_MATRIX_'||rid,0,25,null);
   b:=admin_rental_summary_changes(f,'FILTER_MATRIX_'||rid,0,25,null,array[rid],'{}');
   assert (a->>'total')::integer=case when expected then 1 else 0 end,format('filter %s status %s lock %s: %s',f,st,locked,a);
   assert a->'rows'=b->'rows' and a->'counts'=b->'counts' and a->'total'=b->'total','Delta/list mismatch';
  end loop;
  -- Independent retired-state exclusion and tomorrow vs today boundary.
  perform set_config('session_replication_role','replica',true);
  update vehicles set status='retired',maintenance_lock_active=false where id=car;
  update rentals set return_date=today+1 where id=rid;
  perform set_config('session_replication_role','origin',true);
  assert (admin_rental_list('maintenance','FILTER_MATRIX_'||rid,0,25,null)->>'total')::integer=case when terminal then 0 else 1 end;
  assert (admin_rental_list('ready_pickup','FILTER_MATRIX_'||rid,0,25,null)->>'total')::integer=0;
  assert (admin_rental_list('returns_today','FILTER_MATRIX_'||rid,0,25,null)->>'total')::integer=0;
 end loop;end loop;
 foreach f in array array['needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive','deposit_review'] loop
  a:=admin_rental_list(f,'',0,1,null);
  assert (a->'counts'->>f)::integer=(a->>'total')::integer,'Count does not match unsearched membership';
  ids:='{}';offs:=0;
  loop
   page:=admin_rental_list(f,'FILTER_MATRIX_',offs,2,null);
   exit when jsonb_array_length(page->'rows')=0;
   select ids||coalesce(array_agg((r->>'id')::uuid),'{}') into ids from jsonb_array_elements(page->'rows') r;
   offs:=offs+2;
  end loop;
  assert cardinality(ids)=(page->>'total')::integer,'Page rows lost';
  assert cardinality(ids)=(select count(distinct id) from unnest(ids) id),'Duplicate across pages';
 end loop;
 raise notice 'PASS all nine filters, counts, pagination, Eastern return date and Realtime parity';
end $$;
rollback;
