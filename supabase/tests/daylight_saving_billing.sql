-- Run only against the isolated daylight_saving_billing fixture.
begin;
do $$
declare q jsonb; n integer;
begin
 assert rentmect_billable_days('2026-10-30','6:00 PM','2026-11-01','6:00 PM')=2;
 assert rentmect_billable_days('2026-11-01','12:00 AM','2026-11-02','12:00 AM')=1;
 assert rentmect_billable_days('2027-03-13','6:00 PM','2027-03-14','6:00 PM')=1;
 assert rentmect_billable_days('2027-03-13','6:00 PM','2027-03-14','6:01 PM')=2;
 assert rentmect_billable_days('2026-10-30','6:00 PM','2026-11-01','6:01 PM')=3;
 assert rentmect_billable_days('2026-10-23','6:00 PM','2026-10-25','6:00 PM')=2;
 assert rentmect_add_calendar_rental_days('2026-10-30 18:00 America/New_York',2)='2026-11-01 18:00 America/New_York'::timestamptz;
 assert rentmect_add_calendar_rental_days('2027-03-13 18:00 America/New_York',1)='2027-03-14 18:00 America/New_York'::timestamptz;
 insert into vehicles values('11111111-1111-4111-8111-111111111111',65,300,true);
 q:=get_booking_quote('11111111-1111-4111-8111-111111111111','2027-03-13','2027-03-14','6:00 PM','6:00 PM');
 assert (q->>'valid')::boolean and (q->>'billable_days')::integer=1,q::text;
 assert (q->>'actual_duration_minutes')::integer=1380,q::text;
 assert (q->>'minimum_rental_hours')::integer=24,q::text;
 q:=get_booking_quote('11111111-1111-4111-8111-111111111111','2027-11-06','2027-11-08','6:00 PM','6:00 PM');
 assert (q->>'valid')::boolean and (q->>'base_rental_total')::numeric=130 and (q->>'tax_amount')::numeric=8.26,q::text;
 q:=get_booking_quote(null,'2027-03-13','2027-03-14','6:00 PM','5:59 PM');
 assert not (q->>'valid')::boolean and q->>'error' like '%1 rental day%',q::text;
 insert into pending_bookings(id,status,source,pickup_date,pickup_time,return_date,return_time)
 values('22222222-2222-4222-8222-222222222222','pending','website','2027-03-13','6:00 PM','2027-03-14','6:00 PM');
 insert into rentals(id,status,pickup_date,pickup_time,return_date,return_time)
 values('33333333-3333-4333-8333-333333333333','reserved','2027-03-13','6:00 PM','2027-03-14','6:00 PM');
 assert (select billable_days=1 and actual_duration_minutes=1380 from rentals where id='33333333-3333-4333-8333-333333333333');
 begin
  update pending_bookings set return_time='5:59 PM';
  raise exception 'FAIL: accepted short minimum';
 exception when others then
  if sqlerrm not like 'Rentals require at least 1 rental day%' then raise; end if;
 end;
 -- Stage a fall-back overdue day: 25 actual hours is still one calendar day.
 insert into rentals(id,user_id,vehicle_id,status,pickup_date,pickup_time,return_date,return_time,rental_total)
 values('44444444-4444-4444-8444-444444444444',gen_random_uuid(),'11111111-1111-4111-8111-111111111111','completed','2026-10-30','6:00 PM','2026-10-31','6:00 PM',65);
 update rentals set status='active' where id='44444444-4444-4444-8444-444444444444';
 n:=rentmect_stage_late_return_charges('2026-11-01 18:00 America/New_York');
 assert n=2,'Expected one fixed fee and one day';
 assert rentmect_stage_late_return_charges('2026-11-01 18:00 America/New_York')=0,'Repeated staging must be idempotent';
 assert rentmect_stage_late_return_charges('2026-11-01 18:01 America/New_York')=1,'Genuine extra minute starts another day';
end $$;
rollback;
