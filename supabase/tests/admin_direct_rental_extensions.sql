-- Isolated test database only; synthetic records and payments, rolled back.
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temporary table admin_extension_results(scenario text,result text);
do $test$
declare actor uuid:='11111111-1111-4111-8111-111111111111'; customer uuid:='22222222-2222-4222-8222-222222222222';
  car uuid; replacement uuid; rid uuid; code_id uuid; key uuid; eid uuid; q jsonb; result jsonb; before_periods jsonb;
  r public.rentals%rowtype; kind text;
  end_day date:=(now() at time zone 'America/New_York')::date+3;
begin
  perform set_config('session_replication_role','replica',true);
  insert into auth.users(id) values(actor),(customer) on conflict do nothing;
  insert into public.profiles(id,role,staff_role,date_of_birth)
    values(actor,'admin','owner','1980-01-01'),(customer,'customer','customer','1980-01-01') on conflict do nothing;
  perform set_config('session_replication_role','origin',true);
  foreach kind in array array['no_swap','customer_request','emergency','maintenance'] loop
    begin
      perform set_config('session_replication_role','replica',true);
      insert into public.vehicles(name,daily_rate,security_deposit,status,is_active) values('Test Buick',49,300,'available',true) returning id into car;
      insert into public.vehicles(name,daily_rate,security_deposit,status,is_active) values('Test Audi',69,500,'available',true) returning id into replacement;
      insert into public.discount_codes(code,discount_type,amount,waive_security_deposit)
        values('ADMIN-EXT-'||car,'fixed',10,false) returning id into code_id;
      insert into public.rentals(user_id,vehicle_id,pickup_date,pickup_time,return_date,return_time,status,
        rental_total,base_rental_total,tax_amount,service_fee_total,security_deposit,deposit_held_amount,
        payment_status,paid_at,payment_amount_cents,under_25_markup_percentage,discount_amount,manual_discount_amount,
        cancellation_credit_amount,discount_reserved,discount_code_id,agreement_signed,agreement_snapshot)
      values(customer,car,end_day-10,'9:00 AM',end_day,'9:00 AM','active',480,490,30.48,0,300,300,
        'partially_paid',now(),65415,0,10,0,0,true,code_id,true,'Original signed agreement') returning id into rid;
      insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source)
        values(rid,car,public.rentmect_rental_timestamp(end_day-10,'9:00 AM') at time zone 'America/New_York',
          public.rentmect_rental_timestamp(end_day,'9:00 AM') at time zone 'America/New_York','initial');
      perform set_config('session_replication_role','origin',true);
      if kind<>'no_swap' then
        q:=public.admin_preview_vehicle_swap(rid,replacement,public.rentmect_rental_timestamp(end_day-4,'9:00 AM') at time zone 'America/New_York',
          kind,'Customer agreed to replacement',case when kind='customer_request' then 69 else null end);
        perform public.admin_apply_vehicle_swap(rid,replacement,public.rentmect_rental_timestamp(end_day-4,'9:00 AM') at time zone 'America/New_York',
          kind,'Customer agreed to replacement',case when kind='customer_request' then 69 else null end,gen_random_uuid(),q->>'revision');
      end if;
      before_periods:=public.rentmect_pricing_snapshot(rid);
      -- Added dates must remain subject to inventory and existing request holds.
      begin
        insert into public.vehicle_availability_blocks(vehicle_id,start_date,end_date,start_time,end_time,block_type,active)
          values(case when kind='no_swap' then car else replacement end,end_day+1,end_day+3,'9:00 AM','9:00 AM','maintenance',true);
        begin
          perform public.admin_preview_rental_extension(rid,end_day+4,'9:00 AM',49,'Customer agreed to four added days');
          raise exception 'FAILED calendar conflict protection';
        exception when others then if sqlerrm not like 'Replacement vehicle conflicts%' then raise; end if; end;
        raise exception using errcode='ZX001',message='rollback conflict fixture';
      exception when sqlstate 'ZX001' then null; end;
      begin
        insert into public.rental_extension_requests(rental_id,user_id,request_kind,status,payment_status,
          original_return_date,original_return_time,requested_return_date,requested_return_time)
          values(rid,customer,'same_vehicle_extension','pending','pending',end_day,'9:00 AM',end_day+2,'9:00 AM');
        begin
          perform public.admin_preview_rental_extension(rid,end_day+4,'9:00 AM',49,'Customer agreed to four added days');
          raise exception 'FAILED existing request protection';
        exception when others then if sqlerrm<>'Resolve the existing extension request before creating another extension.' then raise; end if; end;
        raise exception using errcode='ZX001',message='rollback pending request fixture';
      exception when sqlstate 'ZX001' then null; end;
      q:=public.admin_preview_rental_extension(rid,end_day+4,'9:00 AM',49,'Customer agreed to four added days');
      if (q->>'extension_total')::numeric<>208.45 or (q->>'extension_days')::integer<>4 then raise exception 'Wrong extension-only quote'; end if;
      if (q->>'total_due')::numeric<>(case when kind='customer_request' then 449.86 else 364.78 end) then raise exception 'Prior balance missing from review: %',q; end if;
      if exists(select 1 from public.rental_admin_extensions where rental_id=rid) then raise exception 'Preview wrote an extension'; end if;
      key:=gen_random_uuid();
      begin
        perform public.admin_apply_rental_extension(rid,end_day+4,'9:00 AM',69,'Customer agreed to four added days',key,q->>'revision');
        raise exception 'FAILED changed rate protection';
      exception when others then if sqlerrm<>'Rental or payments changed. Review the extension again.' then raise; end if; end;
      result:=public.admin_apply_rental_extension(rid,end_day+4,'9:00 AM',49,'Customer agreed to four added days',key,q->>'revision');
      select * into r from public.rentals where id=rid;
      if r.return_date<>end_day+4 or r.pickup_date<>end_day-10 or r.payment_amount_cents<>65415 or r.security_deposit<>300 or r.discount_amount<>10 then
        raise exception 'Extension failed to preserve original contract and payments'; end if;
      if r.agreement_signed or r.agreement_snapshot is not null then raise exception 'Updated agreement was not requested'; end if;
      if exists(select 1 from public.rental_extension_requests where rental_id=rid) then raise exception 'Admin required a customer request'; end if;
      if (select count(*) from public.rental_pricing_periods where admin_extension_id=key)<>1 then raise exception 'Extension missing or duplicated'; end if;
      if (select sum(billing_units) from public.rental_pricing_periods where rental_id=rid)<>14 then raise exception 'Prior days disappeared or doubled'; end if;
      if exists(select 1 from jsonb_array_elements(before_periods) old_period where not exists(
        select 1 from public.rental_pricing_periods p where p.rental_id=rid
          and p.starts_at=(old_period->>'starts_at')::timestamptz and p.ends_at=(old_period->>'ends_at')::timestamptz
          and p.rental_amount=(old_period->>'rental_amount')::numeric and p.tax_amount=(old_period->>'tax_amount')::numeric)) then
        raise exception 'Admin extension repriced earlier periods'; end if;
      result:=public.admin_apply_rental_extension(rid,end_day+4,'9:00 AM',49,'Customer agreed to four added days',key,q->>'revision');
      if not (result->>'idempotent_replay')::boolean then raise exception 'Retry duplicated extension'; end if;
      result:=public.record_admin_rental_balance_payment(rid,208.45,'cash','Fixture extension payment',actor);
      if (result->>'balance_due')::numeric<>(case when kind='customer_request' then 241.41 else 156.33 end) then raise exception 'Extension payment erased previous debt: %',result; end if;
      set constraints all immediate;
      set constraints all deferred;
      -- A second extension appends to the first and can use the fleet rate.
      q:=public.admin_preview_rental_extension(rid,end_day+5,'10:00 AM',69,'Customer agreed to another extension');
      if (q->>'extension_days')::integer<>2 or (q->>'extension_total')::numeric<>146.76 then raise exception 'Partial-day extension cutoff is wrong'; end if;
      perform public.admin_apply_rental_extension(rid,end_day+5,'10:00 AM',69,'Customer agreed to another extension',gen_random_uuid(),q->>'revision');
      if (select sum(billing_units) from public.rental_pricing_periods where rental_id=rid)<>16 then raise exception 'Repeated extension lost billing units'; end if;
      set constraints all immediate;
      set constraints all deferred;
      perform set_config('request.jwt.claim.sub',customer::text,true);
      begin
        perform public.admin_preview_rental_extension(rid,end_day+8,'9:00 AM',49,'Unauthorized extension attempt');
        raise exception 'FAILED permission guard';
      exception when others then if sqlerrm<>'Rental editing permission is required.' then raise; end if; end;
      perform set_config('request.jwt.claim.sub',actor::text,true);
      raise exception using errcode='ZX001',message='rollback successful scenario';
    exception when sqlstate 'ZX001' then null; end;
    insert into admin_extension_results values(kind||': direct extension, prior balance, payment, retry, separate rates, permissions','passed');
  end loop;
end; $test$;
table admin_extension_results;
rollback;
