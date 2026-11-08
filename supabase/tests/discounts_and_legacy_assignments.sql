-- Isolated database only. Synthetic records, actual RPCs/triggers, all rolled back.
begin;
alter table rentals alter column starting_mileage set default 1000;
alter table rentals alter column ending_mileage set default 1100;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
create temporary table regression_results(scenario text,result text);
do $test$
declare
  actor uuid:='11111111-1111-4111-8111-111111111111';
  customer uuid:='22222222-2222-4222-8222-222222222222';
  rid uuid; car uuid; previous_car uuid; empty_id uuid; key uuid;
  q jsonb; result jsonb; snapshot jsonb; assignment_snapshot jsonb; period_terms jsonb; extension_quotes jsonb;
  r public.rentals%rowtype; kind text; mode text; invalid_case text;
  end_day date:=(now() at time zone 'America/New_York')::date+3;
  rental_before numeric; tax_before numeric; discount_before numeric;
begin
  perform set_config('session_replication_role','replica',true);
  insert into auth.users(id) values(actor),(customer) on conflict do nothing;
  insert into public.profiles(id,role,staff_role,date_of_birth)
    values(actor,'admin','owner','1980-01-01'),(customer,'customer','customer','1980-01-01') on conflict do nothing;
  perform set_config('session_replication_role','origin',true);
  foreach kind in array array['legacy_active','dated','fully_comped'] loop
    begin
      perform set_config('session_replication_role','replica',true);
      insert into public.vehicles(name,daily_rate,security_deposit,status,is_active,published)
        values('Discount test car',49,300,'available',true,false) returning id into car;
      insert into public.vehicles(name,daily_rate,security_deposit,status,is_active,published)
        values('Unused pre-pickup car',69,300,'available',true,false) returning id into previous_car;
      insert into public.rentals(user_id,vehicle_id,pickup_date,pickup_time,return_date,return_time,status,
        rental_total,base_rental_total,tax_amount,service_fee_total,taxable_service_fee_total,
        security_deposit,deposit_held_amount,payment_status,paid_at,payment_amount_cents,
        under_25_markup_percentage,discount_amount,manual_discount_amount,cancellation_credit_amount,
        agreement_signed,agreement_snapshot)
      values(customer,car,end_day-10,'9:00 AM',end_day,'9:00 AM','active',490,490,31.12,0,0,
        300,300,case when kind='fully_comped' then 'pending' else 'partially_paid' end,
        case when kind='fully_comped' then null else now() end,
        case when kind='fully_comped' then 0 else 50000 end,0,0,0,0,true,'Signed agreement') returning id into rid;
      insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source,created_at)
        values(rid,previous_car,public.rentmect_rental_timestamp(end_day-10,'9:00 AM') at time zone 'America/New_York',
          public.rentmect_rental_timestamp(end_day-10,'9:00 AM') at time zone 'America/New_York','initial',now()-interval '1 day')
        returning id into empty_id;
      insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source,created_at)
        values(rid,car,public.rentmect_rental_timestamp(end_day-10,'9:00 AM') at time zone 'America/New_York',
          public.rentmect_rental_timestamp(end_day,'9:00 AM') at time zone 'America/New_York','admin_edit',now());
      perform set_config('session_replication_role','origin',true);
      result:=public.admin_apply_manual_rental_discount(rid,'fixed',10,'Synthetic initial approved discount',gen_random_uuid(),actor);
      update rental_amendments set created_at=clock_timestamp() where id=(result#>>'{amendment,id}')::uuid;
      if kind<>'legacy_active' then
        q:=public.admin_preview_rental_extension(rid,end_day+4,'9:00 AM',69,'Customer agreed to extension');
        perform public.admin_apply_rental_extension(rid,end_day+4,'9:00 AM',69,
          'Customer agreed to extension',gen_random_uuid(),q->>'revision');
        set constraints all immediate;
        set constraints all deferred;
      end if;
      select jsonb_agg(a order by id) into assignment_snapshot from public.rental_vehicle_assignments a where rental_id=rid;
      foreach mode in array array['fixed','percentage','remove'] loop
        select jsonb_agg(to_jsonb(p)-array['rental_amount','tax_amount'] order by starts_at,id)
          into period_terms from public.rental_pricing_periods p where rental_id=rid;
        select jsonb_agg(e order by id) into extension_quotes from public.rental_admin_extensions e where rental_id=rid;
        q:=public.admin_preview_manual_rental_discount(rid,mode,case when mode='fixed' then 40 else 20 end);
        key:=gen_random_uuid();
        -- The actual Edge action uses the service-role RPC with an admin actor.
        perform set_config('request.jwt.claim.sub','',true);
        perform set_config('request.jwt.claim.role','service_role',true);
        result:=public.admin_apply_manual_rental_discount(rid,mode,case when mode='fixed' then 40 else 20 end,
          'Customer courtesy adjustment',key,actor);
        update rental_amendments set created_at=clock_timestamp() where id=(result#>>'{amendment,id}')::uuid;
        perform set_config('request.jwt.claim.sub',actor::text,true);
        perform set_config('request.jwt.claim.role','authenticated',true);
        select * into r from public.rentals where id=rid;
        if r.rental_total<>(q->>'rental_total')::numeric or r.tax_amount<>(q->>'tax_amount')::numeric
          or r.security_deposit<>300 or r.base_rental_total<>490 or r.pickup_date<>end_day-10 then
          raise exception 'Discount preview/apply mismatch or contract changed: %',result;
        end if;
        if kind<>'fully_comped' and (r.payment_amount_cents<>50000 or public.rentmect_rental_net_paid_amount(rid)<>500) then
          raise exception 'Discount changed captured receipts'; end if;
        if (select jsonb_agg(a order by id) from public.rental_vehicle_assignments a where rental_id=rid) is distinct from assignment_snapshot then
          raise exception 'Discount changed possession history'; end if;
        if period_terms is not null and (select jsonb_agg(to_jsonb(p)-array['rental_amount','tax_amount'] order by starts_at,id)
          from public.rental_pricing_periods p where rental_id=rid) is distinct from period_terms then
          raise exception 'Discount changed period dates, rates or units'; end if;
        if (select jsonb_agg(e order by id) from public.rental_admin_extensions e where rental_id=rid) is distinct from extension_quotes then
          raise exception 'Discount rewrote original extension quotes'; end if;
        if kind<>'legacy_active' and ((select sum(rental_amount) from public.rental_pricing_periods where rental_id=rid)<>r.rental_total
          or (select sum(tax_amount) from public.rental_pricing_periods where rental_id=rid)<>r.tax_amount) then
          raise exception 'Discount and pricing periods diverged'; end if;
        snapshot:=public.rentmect_pricing_snapshot(rid);
        result:=public.admin_apply_manual_rental_discount(rid,mode,case when mode='fixed' then 40 else 20 end,
          'Customer courtesy adjustment',key,actor);
        if not (result->>'idempotent_replay')::boolean or public.rentmect_pricing_snapshot(rid) is distinct from snapshot then
          raise exception 'Retry reapplied discount'; end if;
        set constraints all immediate;
        set constraints all deferred;
      end loop;
      if kind='fully_comped' then
        result:=public.admin_apply_manual_rental_discount(rid,'percentage',100,'Comp entire rental subtotal',gen_random_uuid(),actor);
        update rental_amendments set created_at=clock_timestamp() where id=(result#>>'{amendment,id}')::uuid;
        if (select sum(rental_amount) from public.rental_pricing_periods where rental_id=rid)<>0 then
          raise exception 'Full discount did not zero periods'; end if;
        perform public.admin_apply_manual_rental_discount(rid,'remove',0,'Remove courtesy adjustment',gen_random_uuid(),actor);
        if (select sum(rental_amount) from public.rental_pricing_periods where rental_id=rid)<>766 then
          raise exception 'Removing full discount failed'; end if;
      end if;
      -- A later extension must retain the discounted invoice, add just its quote,
      -- and retain the historical empty assignment that used to block saving.
      perform public.admin_apply_manual_rental_discount(rid,'fixed',40,'Customer courtesy adjustment',gen_random_uuid(),actor);
      select rental_total,tax_amount,manual_discount_amount into rental_before,tax_before,discount_before from public.rentals where id=rid;
      q:=public.admin_preview_rental_extension(rid,end_day+7,'9:00 AM',69,'Customer agreed to added dates');
      perform public.admin_apply_rental_extension(rid,end_day+7,'9:00 AM',69,
        'Customer agreed to added dates',gen_random_uuid(),q->>'revision');
      select * into r from public.rentals where id=rid;
      if r.rental_total<>rental_before+(q->>'rental_amount')::numeric
        or r.tax_amount<>tax_before+(q->>'tax_amount')::numeric or r.manual_discount_amount<>discount_before then
        raise exception 'Extension lost discount'; end if;
      if not exists(select 1 from public.rental_vehicle_assignments where id=empty_id and assigned_from=assigned_until) then
        raise exception 'Empty legacy history was deleted'; end if;
      set constraints all immediate;
      set constraints all deferred;
      foreach invalid_case in array array['open','inverted','empty_after_pickup'] loop
        begin
          if invalid_case='open' then update public.rental_vehicle_assignments set assigned_until=null where id=empty_id;
          elsif invalid_case='inverted' then update public.rental_vehicle_assignments set assigned_until=assigned_from-interval '1 second' where id=empty_id;
          else update public.rental_vehicle_assignments set assigned_from=assigned_from+interval '1 day',assigned_until=assigned_until+interval '1 day' where id=empty_id;
          end if;
          set constraints all immediate;
          raise exception 'FAILED invalid assignment guard: %',invalid_case;
        exception when others then
          if sqlerrm not in ('Vehicle assignments must have no gaps or overlaps.',
            'new row for relation "rental_vehicle_assignments" violates check constraint "rental_vehicle_assignments_check"') then raise; end if;
        end;
      end loop;
      begin
        update public.rentals set rental_total=rental_total-1 where id=rid;
        raise exception 'FAILED raw pricing guard';
      exception when others then if sqlerrm<>'Dated rental pricing cannot be overwritten by a whole-rental edit.' then raise; end if; end;
      perform set_config('request.jwt.claim.sub',customer::text,true);
      begin
        perform public.admin_apply_manual_rental_discount(rid,'fixed',50,'Unauthorized discount attempt',gen_random_uuid(),customer);
        raise exception 'FAILED discount permission guard';
      exception when others then if sqlerrm<>'Admin access is required.' then raise; end if; end;
      perform set_config('request.jwt.claim.sub',actor::text,true);
      raise exception using errcode='ZX001',message='rollback successful scenario';
    exception when sqlstate 'ZX001' then null; end;
    insert into regression_results values(kind||': discounts, retry, receipts, extension, history and guards','passed');
  end loop;
end; $test$;
table regression_results;
rollback;
