-- Run inside a transaction with the migration installed; all fixtures roll back.
begin;
select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',
  (select id from public.profiles where role='admin' limit 1))::text,true);
do $$
declare
  actor uuid := auth.uid(); customer uuid := gen_random_uuid(); other_customer uuid := gen_random_uuid();
  email text := 'block-test-' || customer || '@example.invalid';
  other_email text := 'block-test-' || other_customer || '@example.invalid';
  phone text := '2025550198';
  result public.profiles;
begin
  if actor is null then raise exception 'An administrator fixture is required'; end if;
  insert into auth.users(id,email,raw_user_meta_data) values(customer,email,jsonb_build_object('phone',phone));
  insert into auth.users(id,email,raw_user_meta_data) values(other_customer,other_email,'{}');
  result := public.admin_set_customer_status(customer,'blocked','Rollback-only test');
  if not result.blocked_customer then raise exception 'Block flag missing'; end if;
  if not public.rentmect_customer_is_blocked(null,upper(email),null)
    or not public.rentmect_customer_is_blocked(null,null,'+1 (202) 555-0198')
    or public.rentmect_customer_is_blocked(null,'unrelated@example.invalid','2025550197') then
    raise exception 'Identity normalization failed';
  end if;
  begin
    insert into auth.users(id,email) values(gen_random_uuid(),upper(email));
    raise exception 'Blocked email signup accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into auth.users(id,email,raw_user_meta_data) values(gen_random_uuid(),'new-'||email,jsonb_build_object('phone','1-202-555-0198'));
    raise exception 'Blocked metadata phone signup accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into auth.users(id,email,phone) values(gen_random_uuid(),'phone-'||email,'+12025550198');
    raise exception 'Blocked auth phone signup accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    update auth.users set email=auth.users.email || '.changed' where id=customer;
    raise exception 'Blocked auth email change accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    update public.profiles set phone='+1 (202) 555-0198' where id=other_customer;
    raise exception 'Blocked phone profile change accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into public.rentals(user_id) values(customer);
    raise exception 'Blocked rental insert accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into public.pending_bookings(customer_email) values(upper(email));
    raise exception 'Blocked guest booking accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into public.pending_bookings(customer_phone) values('(202) 555-0198');
    raise exception 'Blocked phone booking accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    insert into public.rental_extension_requests(user_id) values(customer);
    raise exception 'Blocked extension accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',customer)::text,true);
  begin
    -- Even an employee who can view customers cannot unblock without management permission.
  update public.employee_permissions set enabled=false where permission_key='customer.manage';
  if (select staff_role from public.profiles where id=actor)='employee' then
    begin
      perform public.admin_set_customer_status(customer,'good');
      raise exception 'Unauthorized employee unblock accepted';
    exception when others then if sqlerrm not like '%permission is required%' then raise; end if; end;
  end if;
  update public.employee_permissions set enabled=true where permission_key='customer.manage';
  perform public.admin_set_customer_status(customer,'good');
    raise exception 'Customer self-unblock accepted';
  exception when others then if sqlerrm not like '%permission is required%' then raise; end if; end;
  begin
    update public.profiles set blocked_customer=false,customer_status='good' where id=customer;
    raise exception 'Direct customer self-unblock accepted';
  exception when others then if sqlerrm not like '%permission is required%' then raise; end if; end;
  begin
    update public.profiles set phone='2025550197' where id=customer;
    raise exception 'Customer contact escape accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',actor)::text,true);
  update public.profiles set phone='2025550197' where id=customer;
  if not public.rentmect_customer_is_blocked(null,null,phone) or not public.rentmect_customer_is_blocked(null,null,'2025550197') then
    raise exception 'Contact correction lost historical block';
  end if;
  perform public.admin_set_customer_status(customer,'good');
  if public.rentmect_customer_is_blocked(customer) or public.rentmect_customer_is_blocked(null,email,phone) then
    raise exception 'Unblock did not clear saved identities';
  end if;
  perform public.admin_set_customer_status(customer,'blocked','Deletion test');
  delete from auth.users where id=customer;
  if not public.rentmect_customer_is_blocked(null,email,'2025550197') then raise exception 'Account deletion cleared block'; end if;
  begin
    insert into auth.users(id,email) values(gen_random_uuid(),email);
    raise exception 'Deleted blocked email signup accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  -- Exercise update routing on isolated copies: no live rental changes or notifications.
  -- The production trigger dispatches by table name, so use a temporary rentals table.
  create temporary table rentals (like public.rentals including defaults);
  insert into pg_temp.rentals(id,user_id,status,pickup_date,return_date,pickup_time,return_time)
    values(gen_random_uuid(),other_customer,'approved',current_date+5,current_date+8,'9:00 AM','9:00 AM');
  create trigger block_guard before insert or update on pg_temp.rentals
    for each row execute function public.rentmect_guard_blocked_booking();
  perform public.admin_set_customer_status(other_customer,'blocked','Existing rental test');
  begin
    update pg_temp.rentals set status='active';
    raise exception 'Blocked pickup accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  begin
    update pg_temp.rentals set return_date=return_date+1;
    raise exception 'Blocked rental extension accepted';
  exception when others then if sqlerrm not like '%This customer is blocked%' then raise; end if; end;
  update pg_temp.rentals set status='return_initiated';
  update pg_temp.rentals set status='completed';
  update pg_temp.rentals set status='cancelled';
  if not exists(select 1 from pg_temp.rentals where status='cancelled') then raise exception 'Cancellation prevented'; end if;
  -- Removing one source block must not clear another source's identical identity.
  insert into public.customer_identity_blocks values(customer,'email',other_email,now());
  perform public.admin_set_customer_status(other_customer,'good');
  if not public.rentmect_customer_is_blocked(other_customer) then raise exception 'Another source block was removed'; end if;
  raise notice 'PASS: block/unblock, signup, normalization, contact changes, bookings, extensions, authorization, deletion persistence';
end;
$$;
rollback;
