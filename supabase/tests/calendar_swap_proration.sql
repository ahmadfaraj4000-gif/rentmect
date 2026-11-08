begin;
set local request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
do $$ declare rid uuid; car uuid; q jsonb; r rentals%rowtype; begin
 assert rentmect_pricing_fraction('2026-10-28 09:00 America/New_York','2026-11-07 09:00 America/New_York','2026-11-03 09:00 America/New_York')=0.6;
 assert rentmect_pricing_fraction('2026-03-04 09:00 America/New_York','2026-03-14 09:00 America/New_York','2026-03-10 09:00 America/New_York')=0.6;
 assert rentmect_pricing_fraction('2026-10-28 09:00 America/New_York','2026-11-07 09:00 America/New_York','2026-11-03 21:00 America/New_York')=0.65;
 assert rentmect_pricing_fraction('2026-10-28 09:00 America/New_York','2026-11-07 09:00 America/New_York','2026-10-20 09:00 America/New_York')=0;
 assert rentmect_pricing_fraction('2026-10-28 09:00 America/New_York','2026-11-07 09:00 America/New_York','2026-11-08 09:00 America/New_York')=1;
 rid:=pg_temp.account_fixture(300,813.67);
 set local session_replication_role='replica';
 update rentals set pickup_date='2026-10-28',return_date='2026-11-07',pickup_time='9:00 AM',return_time='9:00 AM',rental_total=690,base_rental_total=690,tax_amount=43.82 where id=rid;
 update rental_vehicle_assignments set assigned_from='2026-10-28 09:00 America/New_York',assigned_until='2026-11-07 09:00 America/New_York' where rental_id=rid;
 set local session_replication_role='origin';
 insert into vehicles(name,daily_rate,security_deposit,status,published) values('Synthetic calendar swap',89,300,'available',false) returning id into car;
 q:=admin_preview_vehicle_swap(rid,car,'2026-11-03 09:00 America/New_York','customer_request','Approved higher daily rate',89,1000,0);
 assert (q->>'total_delta')::numeric=85.08,q::text;
 perform admin_apply_vehicle_swap(rid,car,'2026-11-03 09:00 America/New_York','customer_request','Approved higher daily rate',89,gen_random_uuid(),q->>'revision',1000,0);
 select * into r from rentals where id=rid;
 assert r.rental_total=770 and r.tax_amount=48.90;
 assert rentmect_rental_net_paid_amount(rid)=813.67 and r.deposit_held_amount=300;
 perform rentmect_assert_period_financial_totals(rid);
end $$;
rollback;
