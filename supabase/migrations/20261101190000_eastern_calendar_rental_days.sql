begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

-- Rental days follow scheduled Eastern wall time. Clock changes never add or
-- remove a billed day; genuine time beyond the return clock time still rounds up.
create or replace function public.rentmect_billable_days(
  p_pickup_date date, p_pickup_time text, p_return_date date, p_return_time text
) returns integer language sql immutable security definer set search_path=public as $$
  select greatest(1, ceil(extract(epoch from (
    public.rentmect_rental_timestamp(p_return_date,p_return_time)
    - public.rentmect_rental_timestamp(p_pickup_date,p_pickup_time)
  )) / 86400.0)::integer);
$$;
comment on function public.rentmect_billable_days(date,text,date,text) is
  'Started rental days measured in Eastern local calendar time, independent of DST offset changes.';

create or replace function public.rentmect_add_calendar_rental_days(p_start timestamptz,p_days integer)
returns timestamptz language sql immutable set search_path=public as $$
  select ((p_start at time zone 'America/New_York') + make_interval(days=>p_days))
    at time zone 'America/New_York';
$$;
revoke all on function public.rentmect_add_calendar_rental_days(timestamptz,integer) from public;
grant execute on function public.rentmect_add_calendar_rental_days(timestamptz,integer) to anon,authenticated,service_role;

-- Preserve the current quote/booking guards; change only their minimum-return
-- deadline. Advance notice, payment expiry and actual elapsed minutes stay real time.
do $migration$
declare name text; definition text; old_expression text; new_expression text;
begin
  foreach name in array array['get_booking_quote','enforce_booking_policy_on_pending_booking','enforce_booking_policy_on_rental'] loop
    select pg_get_functiondef(p.oid) into strict definition from pg_proc p
      where p.pronamespace='public'::regnamespace and p.proname=name;
    old_expression:=case name
      when 'get_booking_quote' then 'v_pickup_at + make_interval(hours => v_policy.minimum_rental_days * 24)'
      when 'enforce_booking_policy_on_pending_booking' then 'v_pickup_at + make_interval(hours => new.minimum_rental_days_applied * 24)'
      else 'v_pickup_at + make_interval(hours => coalesce(new.minimum_rental_days_applied, 1) * 24)' end;
    new_expression:=case name
      when 'get_booking_quote' then 'public.rentmect_add_calendar_rental_days(v_pickup_at,v_policy.minimum_rental_days)'
      when 'enforce_booking_policy_on_pending_booking' then 'public.rentmect_add_calendar_rental_days(v_pickup_at,new.minimum_rental_days_applied)'
      else 'public.rentmect_add_calendar_rental_days(v_pickup_at,coalesce(new.minimum_rental_days_applied,1))' end;
    if position(old_expression in definition)=0 then raise exception 'Review changed DST booking function: %',name; end if;
    definition:=replace(definition,old_expression,new_expression);
    definition:=replace(definition,'Rentals require at least %s hours.','Rentals require at least %s rental day(s), ending at the same Eastern time.');
    definition:=replace(definition,'Rentals require at least % hours.','Rentals require at least % rental day(s), ending at the same Eastern time.');
    -- Only the error-message arguments, not the compatibility minimum_rental_hours field.
    definition:=replace(definition,'          v_policy.minimum_rental_days * 24,'||chr(10),'          v_policy.minimum_rental_days,'||chr(10));
    definition:=replace(definition,'new.minimum_rental_days_applied * 24,'||chr(10),'new.minimum_rental_days_applied,'||chr(10));
    definition:=replace(definition,'coalesce(new.minimum_rental_days_applied, 1) * 24,'||chr(10),'coalesce(new.minimum_rental_days_applied, 1),'||chr(10));
    execute definition;
  end loop;

  -- Late-day numbering uses the same calendar boundary. The existing grace
  -- period, fixed late fee, unique source IDs and earned-time checks are retained.
  select pg_get_functiondef('public.rentmect_stage_late_return_charges(timestamptz)'::regprocedure) into definition;
  old_expression:='extract(epoch from (p_as_of - late_rentals.due_at))';
  if position(old_expression in definition)=0 then raise exception 'Review changed late rental day calculation.'; end if;
  execute replace(definition,old_expression,
    'extract(epoch from ((p_as_of at time zone ''America/New_York'') - (late_rentals.due_at at time zone ''America/New_York'')))');
end; $migration$;
notify pgrst,'reload schema';
commit;
