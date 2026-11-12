\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql

do $$
declare rid uuid; q jsonb; saved jsonb; key uuid:=gen_random_uuid(); effective timestamptz; history jsonb; paid numeric; old_total numeric;
begin
 rid:=pg_temp.account_fixture(300,813.67);
 q:=public.admin_preview_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price');
 perform public.admin_apply_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price',gen_random_uuid(),q->>'revision');
 effective:=(current_date+2+time '09:00') at time zone 'America/New_York';
 select jsonb_agg(to_jsonb(p)) into history from rental_pricing_periods p where rental_id=rid and ends_at<=effective;
 paid:=public.rentmect_rental_net_paid_amount(rid);
 select rental_total into old_total from rentals where id=rid;
 q:=public.admin_preview_rental_rate_change(rid,effective,55,'Customer agreed to the new rate');
 assert (q->>'rental_delta')::numeric=50, 'Only the last five days should increase';
 assert (q->>'tax_delta')::numeric=3.18;
 saved:=public.admin_apply_rental_rate_change(rid,effective,55,'Customer agreed to the new rate',key,q->>'revision');
 assert (select rental_total=old_total+50 and deposit_held_amount=300 and not agreement_signed and return_date=current_date+7 from rentals where id=rid);
 assert (select jsonb_agg(to_jsonb(p))=history from rental_pricing_periods p where rental_id=rid and ends_at<=((current_date+time '09:00') at time zone 'America/New_York')), 'Earlier original period changed';
 assert (select rental_amount=90 and daily_rate=45 from rental_pricing_periods where rental_id=rid and ends_at=effective), 'Pre-change days must retain their price';
 assert (select rental_amount=275 and daily_rate=55 from rental_pricing_periods where rental_id=rid and starts_at=effective);
 assert public.rentmect_rental_net_paid_amount(rid)=paid, 'Payment history changed';
 saved:=public.admin_apply_rental_rate_change(rid,effective,55,'Customer agreed to the new rate',key,'old');
 assert (saved->>'idempotent_replay')::boolean;
 begin
  perform public.admin_apply_rental_rate_change(rid,effective,60,'Customer agreed to another rate',gen_random_uuid(),q->>'revision');
  raise exception 'Stale price accepted';
 exception when others then if SQLERRM not like '%Review the price change again%' then raise; end if; end;
 -- A second dated price decrease affects only the last two days.
 q:=public.admin_preview_rental_rate_change(rid,effective+interval '3 days',50,'Customer agreed to a reduced rate');
 assert (q->>'rental_delta')::numeric=-10;
 perform public.admin_apply_rental_rate_change(rid,effective+interval '3 days',50,'Customer agreed to a reduced rate',gen_random_uuid(),q->>'revision');
 assert (select rental_amount=90 from rental_pricing_periods where rental_id=rid and ends_at=effective);
 set constraints all immediate; set constraints all deferred;
 raise notice 'PASS dated increase/decrease, unchanged history/payments/deposit, split periods, idempotency and stale preview';
end $$;

do $$
declare rid uuid; q jsonb; effective timestamptz;
begin
 rid:=pg_temp.account_fixture(300,813.67);
 q:=public.admin_preview_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price');
 perform public.admin_apply_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price',gen_random_uuid(),q->>'revision');
 effective:=(current_date+time '21:00') at time zone 'America/New_York';
 q:=public.admin_preview_rental_rate_change(rid,effective,55,'Customer agreed to partial day');
 assert (q->>'rental_delta')::numeric=65,'Half-day boundary must be prorated';
 perform public.admin_apply_rental_rate_change(rid,effective,55,'Customer agreed to partial day',gen_random_uuid(),q->>'revision');
 assert (select rental_amount=22.50 and tax_amount=1.43 from rental_pricing_periods where rental_id=rid and ends_at=effective);
 begin
  perform public.admin_preview_rental_rate_change(rid,effective+interval '9 days',60,'Outside the booked rental');
  raise exception 'Invalid boundary accepted';
 exception when others then if SQLERRM not like '%Choose a start within%' then raise; end if; end;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 begin
  perform public.admin_preview_rental_rate_change(rid,effective,60,'Unauthorized price change');
  raise exception 'Missing permission accepted';
 exception when others then if SQLERRM not like '%permission is required%' then raise; end if; end;
 set constraints all immediate;
 raise notice 'PASS partial-day rounding, boundary validation and permissions';
end $$;
set constraints all deferred;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
do $$
declare rid uuid; q jsonb; effective timestamptz; earlier jsonb; before_amount numeric; paid numeric; cid uuid;
begin
 rid:=pg_temp.account_fixture(300,813.67);
 q:=public.admin_preview_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price');
 perform public.admin_apply_rental_extension(rid,current_date+7,'9:00 AM',45,'Agreed weekly rental price',gen_random_uuid(),q->>'revision');
 perform public.admin_apply_manual_rental_discount(rid,'fixed',40,'Agreed discount is preserved',gen_random_uuid(),auth.uid());
 effective:=(current_date+time '09:00') at time zone 'America/New_York';
 select jsonb_agg(to_jsonb(p)) into earlier from rental_pricing_periods p where rental_id=rid and ends_at<=effective;
 select rental_amount into before_amount from rental_pricing_periods where rental_id=rid and starts_at=effective;
 paid:=public.rentmect_rental_net_paid_amount(rid);
 q:=public.admin_preview_rental_rate_change(rid,effective,55,'Agreed higher rate after discount');
 perform public.admin_apply_rental_rate_change(rid,effective,55,'Agreed higher rate after discount',gen_random_uuid(),q->>'revision');
 assert (select rental_amount=before_amount+70 from rental_pricing_periods where rental_id=rid and starts_at=effective), 'Discount was lost';
 assert (select jsonb_agg(to_jsonb(p))=earlier from rental_pricing_periods p where rental_id=rid and ends_at<=effective), 'Discounted earlier dates changed';
 assert public.rentmect_rental_net_paid_amount(rid)=paid;
 -- Payment in flight must prevent repricing its collection targets.
 insert into rental_charge_items(rental_id,user_id,name,charge_type,amount,total_amount,status,stripe_checkout_session_id)
 select id,user_id,'Synthetic in-flight collection','cleaning',10,10,'checkout_open','cs_synthetic_open' from rentals where id=rid returning id into cid;
 begin
  perform public.admin_preview_rental_rate_change(rid,effective,60,'Agreed price while payment open');
  raise exception 'Open payment was accepted';
 exception when others then if SQLERRM not like '%unfinished payment%' then raise; end if; end;
 set constraints all immediate;
 raise notice 'PASS existing discounts and historical periods preserved; open collection blocked';
end $$;
rollback;
