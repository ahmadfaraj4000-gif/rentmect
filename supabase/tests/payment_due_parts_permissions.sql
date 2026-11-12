\set ON_ERROR_STOP on
begin;
set request.jwt.claim.sub='11111111-1111-4111-8111-111111111111';
set request.jwt.claim.role='authenticated';
\ir fixtures/account_fixture.sql
select set_config('test.rental_id',pg_temp.account_fixture(300,0)::text,true);
set local role authenticated;
do $$ declare s jsonb; begin
 s:=public.admin_flexible_payment_state(current_setting('test.rental_id')::uuid);
 assert (s->'dueParts'->>'depositDueCents')::integer=30000;
 assert (s->'dueParts'->>'rentalDueCents')::integer=51367;
 assert not has_function_privilege(current_user,'public.rentmect_rental_invoice_total(uuid)','execute');
end $$;
-- An authenticated customer cannot use the elevated helper.
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
do $$ begin
 begin
  perform public.rentmect_payment_due_parts(current_setting('test.rental_id')::uuid);
  raise exception 'Unauthorized customer was accepted';
 exception when others then if sqlerrm <> 'Payment access required.' then raise; end if; end;
end $$;
reset role;
rollback;
