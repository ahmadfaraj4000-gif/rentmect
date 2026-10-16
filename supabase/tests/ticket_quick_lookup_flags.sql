-- Isolated database only. Synthetic data rolls back.
\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/ticket_account_fixture.sql

do $$declare rid uuid:=pg_temp.ticket_account_fixture(); car uuid; uid uuid; tid uuid:=gen_random_uuid(); d jsonb; m jsonb; c jsonb; n bigint; charges bigint; snapshot jsonb; begin
 perform set_config('session_replication_role','replica',true);
 update rentals set pickup_date='2026-10-01',return_date='2026-10-05',status='completed',inspection_completed_at='2026-10-05T13:00:00Z' where id=rid returning vehicle_id,user_id into car,uid;
 update rental_vehicle_assignments set assigned_from='2026-10-01T13:00:00Z',assigned_until='2026-10-05T13:00:00Z' where rental_id=rid;
 perform set_config('session_replication_role','origin',true);
 d:=jsonb_build_object('agency','Synthetic flag test','ticket_number',tid,'vehicle_id',car,'violation_date','2026-10-03','violation_time','19:55:19','timezone','America/New_York','amount',50);
 select count(*) into n from ticket_cases;
 select count(*) into charges from rental_charge_items;
 select to_jsonb(r) into snapshot from rentals r where id=rid;
 m:=admin_ticket_lookup(d);
 assert jsonb_array_length(m->'candidates')=1;
 assert m->'candidates'->0->>'id'=rid::text;
 assert (m->>'window_start')::timestamptz='2026-10-03T23:55:19Z'::timestamptz;
 assert (select count(*) from ticket_cases)=n,'Lookup created a case';
 perform admin_ticket_save(tid,null,d);
 begin perform admin_ticket_customer_flag(tid,1,true,'Review this customer before renting again'); raise exception 'Unconfirmed flag accepted'; exception when others then if SQLERRM not like '%Confirm the renter%' then raise; end if; end;
 m:=admin_ticket_candidates(tid);
 perform admin_ticket_action(tid,1,'confirm',jsonb_build_object('rental_id',rid,'token',m->>'token','note','Synthetic agreement evidence verified'));
 c:=admin_ticket_customer_flag(tid,2,true,'Review ticket and original charges before renting again');
 assert (c->>'customer_flag_active')::boolean;
 assert jsonb_array_length(admin_ticket_customer_flags(array[uid]))=1;
 assert jsonb_array_length(admin_ticket_customer_flags(array[gen_random_uuid()]))=0;
 begin perform admin_ticket_customer_flag(tid,2,false,'Stale clear should be rejected'); raise exception 'Stale flag accepted'; exception when serialization_failure then null; end;
 perform admin_ticket_action(tid,3,'resolve','{"outcome":"paid_to_agency","paid_by":"Business","note":"Agency paid; reimbursement still under review"}');
 assert jsonb_array_length(admin_ticket_customer_flags(array[uid]))=1,'Agency payment cleared customer flag';
 perform admin_ticket_customer_flag(tid,4,false,'Customer reimbursement verified by staff');
 assert jsonb_array_length(admin_ticket_customer_flags(array[uid]))=0;
 perform admin_ticket_customer_flag(tid,5,true,'Reopened review after discovering new evidence');
 perform admin_ticket_action(tid,6,'reopen','{"note":"Check correction to ticket time"}');
 perform admin_ticket_save(tid,7,d||'{"violation_time":"20:00:00"}');
 assert jsonb_array_length(admin_ticket_customer_flags(array[uid]))=0,'Match change left stale customer flag';
 assert exists(select 1 from ticket_activity where ticket_id=tid and action='customer_flag_cleared');
 assert (select count(*) from rental_charge_items)=charges;
 assert (select to_jsonb(r) from rentals r where id=rid)=snapshot;
 perform set_config('request.jwt.claim.sub',uid::text,true);
 begin perform admin_ticket_customer_flags(array[uid]); raise exception 'Customer read staff flags'; exception when insufficient_privilege then null; end;
 begin perform admin_ticket_customer_flag(tid,8,true,'Customer cannot change flags'); raise exception 'Customer changed flag'; exception when insufficient_privilege then null; end;
 begin perform admin_ticket_lookup(d); raise exception 'Customer accessed lookup'; exception when insufficient_privilege then null; end;
 raise notice 'PASS read-only quick lookup, historical match, confirmed-only flag, future customer lookup, stale version, agency payment independent of reimbursement, clear/reflag, automatic invalidation, permission denial and no financial/rental side effects';
end$$;
rollback;
