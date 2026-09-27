-- All fixtures, notifications, and audit events roll back. No provider calls.
begin;
select set_config('request.jwt.claims', jsonb_build_object(
  'role', 'service_role', 'sub',
  (select id from public.profiles where role = 'admin' order by created_at limit 1)
)::text, true);

create temporary table deposit_test_results (booking_cases integer, result text) on commit drop;

do $test$
declare
  actor uuid := auth.uid();
  vehicle uuid;
  replacement uuid;
  hold_id uuid;
  rental public.rentals%rowtype;
  quote jsonb;
  preview jsonb;
  base numeric;
  expected numeric;
  age_years integer;
  route text;
  today date := (now() at time zone 'America/New_York')::date;
  pickup date := today + 60;
  checks integer := 0;
begin
  if actor is null then raise exception 'An admin fixture is required'; end if;
  if exists (select 1 from pg_trigger where tgrelid='public.rentals'::regclass and tgname='rentals_enforce_age_deposit') then
    raise exception 'Conflicting legacy trigger is still installed';
  end if;
  insert into public.vehicles(name, daily_rate, security_deposit, status, published)
    values ('Rollback-only deposit fixture',59,350,'available',false) returning id into vehicle;
  insert into public.vehicles(name, daily_rate, security_deposit, status, published)
    values ('Rollback-only replacement fixture',59,450,'available',false) returning id into replacement;

  foreach base in array array[0,350,400,725.50]::numeric[] loop
    update public.vehicles set security_deposit=base
      where id in (vehicle,'00000000-0000-4000-8000-000000000015'::uuid);
    quote := public.get_booking_quote(vehicle,pickup,pickup+2,'9:00 AM','9:00 AM');
    if (quote->>'security_deposit')::numeric is distinct from base
       or (quote->>'under_25_security_deposit')::numeric is distinct from base+200 then
      raise exception 'Quote mismatch: %',quote;
    end if;
    foreach age_years in array array[24,25,40] loop
      update public.profiles
        set date_of_birth=(today - make_interval(years=>age_years))::date
        where id=actor;
      expected := base + case when age_years<25 then 200 else 0 end;
      foreach route in array array['admin','customer','website','preview'] loop
        -- Nested rollback prevents reservations overlapping across cases.
        begin
          if route='admin' then
            rental := public.admin_create_manual_rental(actor,vehicle,pickup,pickup+2,'9:00 AM','9:00 AM');
          elsif route='customer' then
            rental := public.create_rental_with_lock(vehicle,pickup,pickup+2,'9:00 AM','9:00 AM');
          elsif route='preview' then
            rental := public.create_booking_flow_test_rental(pickup,pickup+2,'9:00 AM','9:00 AM');
          else
            insert into public.pending_bookings(
              vehicle_id,user_id,source,status,pickup_date,return_date,pickup_time,return_time,expires_at
            ) values (vehicle,actor,'website','pending',pickup,pickup+2,'9:00 AM','9:00 AM',now()+interval '25 minutes')
            returning id into hold_id;
            rental := public.convert_website_hold_to_rental(hold_id,null);
          end if;
          if rental.base_security_deposit is distinct from base or rental.security_deposit is distinct from expected then
            raise exception 'Wrong deposit on % age % base %: base %, charged %',
              route,age_years,base,rental.base_security_deposit,rental.security_deposit;
          end if;
          if rental.under_25_deposit_adjustment_value is distinct from (case when age_years<25 then 200 else 0 end) then
            raise exception 'Wrong surcharge snapshot';
          end if;
          if route in ('admin','customer') and not exists (
            select 1 from public.rental_audit_events
            where rental_id=rental.id and event_type in ('manual_rental_created','rental_created')
              and (event_payload->>'security_deposit')::numeric=expected
          ) then raise exception 'Creation audit deposit differs from saved deposit'; end if;

          -- Repricing after dates or verified DOB update must retain policy.
          update public.rentals set return_date=pickup+3,user_id=actor where id=rental.id;
          if (select security_deposit from public.rentals where id=rental.id) is distinct from expected then
            raise exception 'Repricing reintroduced a flat deposit';
          end if;

          preview := public.admin_preview_rental_amendment(
            rental.id,replacement,pickup,'9:00 AM',pickup+3,'9:00 AM',null,null);
          if (preview#>>'{new,security_deposit}')::numeric is distinct from
             (450 + case when age_years<25 then 200 else 0 end) then
            raise exception 'Replacement vehicle uses wrong deposit: %',preview;
          end if;
          preview := public.admin_preview_rental_amendment(
            rental.id,replacement,pickup,'9:00 AM',pickup+3,'9:00 AM',null,expected);
          if (preview#>>'{new,security_deposit}')::numeric is distinct from expected then
            raise exception 'Explicit keep-existing deposit choice was lost';
          end if;
          raise exception using errcode='Z0001',message='rollback case';
        exception when sqlstate 'Z0001' then null; end;
        checks := checks+1;
      end loop;
    end loop;
  end loop;

  -- Stale admin pages cannot change the fixed policy.
  begin
    update public.under_25_pricing_settings set deposit_adjustment_value=250 where id=true;
    raise exception 'Conflicting surcharge accepted';
  exception when check_violation then null; end;
  begin
    update public.under_25_pricing_settings set deposit_adjustment_enabled=false where id=true;
    raise exception 'Disabled surcharge accepted';
  exception when check_violation then null; end;
  insert into deposit_test_results values (checks,'passed');
  raise notice 'Passed % booking cases, public quotes, age boundary, repricing, swap previews, overrides, and fixed-policy guards',checks;
end;
$test$;
select * from deposit_test_results;
rollback;
