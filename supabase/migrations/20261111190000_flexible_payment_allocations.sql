-- Compatible, opt-in allocation accounting. Legacy receipts retain their original readers.
begin;
set local lock_timeout='5s';
alter table public.external_payment_receipts
 add column allocation_version integer not null default 1 check(allocation_version in (1,2)),
 add column funding_kind text not null default 'external' check(funding_kind in ('external','credit','stripe')),
 add column credit_amount_cents integer not null default 0 check(credit_amount_cents>=0),
 add column stripe_checkout_session_id text unique,
 add column stripe_payment_intent_id text unique;
alter table public.rental_charge_items
 add column allocation_managed boolean not null default false,
 add column allocated_payment_cents integer not null default 0 check(allocated_payment_cents>=0),
 add column allocated_deposit_cents integer not null default 0 check(allocated_deposit_cents>=0),
 add column allocated_waiver_cents integer not null default 0 check(allocated_waiver_cents>=0),
 add column flex_payment_receipt_id uuid references public.external_payment_receipts(id),
 add constraint allocated_charge_amount check(allocated_payment_cents+allocated_waiver_cents+allocated_deposit_cents<=round(total_amount*100));
alter table public.rental_deposit_allocations add column flex_payment_receipt_id uuid references public.external_payment_receipts(id);
create table public.customer_credit_applications (
 source_receipt_id uuid not null references public.external_payment_receipts(id),
 receipt_id uuid not null references public.external_payment_receipts(id),
 amount_cents integer not null check(amount_cents>0),
 primary key(source_receipt_id,receipt_id),check(source_receipt_id<>receipt_id)
);
alter table public.customer_credit_applications enable row level security;
revoke all on public.customer_credit_applications from public,anon,authenticated;
grant select on public.customer_credit_applications to authenticated;
grant all on public.customer_credit_applications to service_role;
create policy staff_read_customer_credit on public.customer_credit_applications for select to authenticated
 using(public.is_admin() and (public.rentmect_has_permission('payment.collect') or public.rentmect_has_permission('charge.manage') or public.rentmect_has_permission('tab.payments')));

-- Cancellation tombstones also cover a lost response before the receipt exists.
-- Rental locking serializes cancellation against a delayed prepare request.
create table public.external_payment_cancellations (
 id uuid primary key, rental_id uuid not null references public.rentals(id),
 actor_id uuid not null references auth.users(id), created_at timestamptz not null default now()
);
alter table public.external_payment_cancellations enable row level security;
revoke all on public.external_payment_cancellations from public,anon,authenticated;
grant all on public.external_payment_cancellations to service_role;

create function public.rentmect_charge_remaining_amount(c public.rental_charge_items) returns numeric
language sql immutable set search_path=public as $$
 select case when c.status in ('paid','waived','cancelled') or c.included_in_initial_payment then 0
 else greatest(0,c.total_amount-(c.allocated_payment_cents+c.allocated_waiver_cents+c.allocated_deposit_cents)/100.0) end
$$;
create function public.rental_available_credit_cents(p_rental_id uuid) returns bigint
language sql stable security invoker set search_path=public as $$
 select coalesce(sum(r.credit_amount_cents-coalesce((select sum(a.amount_cents) from customer_credit_applications a
 join external_payment_receipts used on used.id=a.receipt_id where a.source_receipt_id=r.id and used.status in ('pending','posted')),0)),0)
 from external_payment_receipts r where r.rental_id=p_rental_id and r.status='posted' and r.funding_kind<>'credit'
$$;
revoke all on function public.rental_available_credit_cents(uuid) from public,anon;
grant execute on function public.rental_available_credit_cents(uuid) to authenticated,service_role;

alter function public.service_prepare_external_payment(uuid,uuid,uuid,jsonb) rename to service_prepare_external_payment_v1;
alter function public.service_finish_external_payment(uuid,uuid,boolean) rename to service_finish_external_payment_v1;
alter function public.admin_refund_external_payment(uuid,text,text) rename to admin_refund_external_payment_v1;
revoke all on function public.service_prepare_external_payment_v1(uuid,uuid,uuid,jsonb),public.service_finish_external_payment_v1(uuid,uuid,boolean),public.admin_refund_external_payment_v1(uuid,text,text) from public,anon,authenticated;
create function public.service_prepare_external_payment(p_id uuid,p_rental_id uuid,p_actor_id uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; receipt external_payment_receipts%rowtype; ids uuid[]; n integer; total bigint;
 rent_cents integer; due integer; item jsonb; before_setting text; paths jsonb; credit_cents integer; funding text; source record; needed integer; take_cents integer;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 if coalesce((p_request->>'version')::integer,1)=1 then
  if exists(select 1 from jsonb_array_elements(p_request->'charges') x join rental_charge_items c on c.id=(x->>'id')::uuid where c.allocation_managed) then raise exception 'Use flexible Receive Payment for this charge.'; end if;
  return service_prepare_external_payment_v1(p_id,p_rental_id,p_actor_id,p_request);
 end if;
 if (p_request->>'version')::integer<>2 then raise exception 'Unsupported payment version.'; end if;
 funding:=coalesce(p_request->>'funding','external');
 if funding not in ('external','credit') then raise exception 'This backend has not enabled the requested collection method.'; end if;
 credit_cents:=(p_request->>'creditAmountCents')::integer;
 if credit_cents is null or credit_cents<0 then raise exception 'Invalid unapplied credit.'; end if;
 if credit_cents>0 or funding='credit' then perform require_external_payment_actor(p_actor_id,'payment.collect'); end if;
 if funding='credit' and credit_cents<>0 then raise exception 'Allocate the applied credit in full.'; end if;
 if p_id is null or jsonb_typeof(p_request->'charges') is distinct from 'array' then raise exception 'Provide a payment key and allocations.'; end if;
 if jsonb_array_length(p_request->'charges')>500 then raise exception 'Select up to 500 charges.'; end if;
 rent_cents:=(p_request->>'rentalAmountCents')::integer;
 if rent_cents is null or rent_cents<0 or (p_request->>'amountCents')::integer<=0 then raise exception 'Invalid payment amount.'; end if;
 if rent_cents>0 then perform require_external_payment_actor(p_actor_id,'payment.collect'); end if;
 if jsonb_array_length(p_request->'charges')>0 then perform require_external_payment_actor(p_actor_id,'charge.manage'); end if;
 if rent_cents=0 and jsonb_array_length(p_request->'charges')=0 and credit_cents=0 then raise exception 'Choose a payment allocation.'; end if;
 select * into strict r from rentals where id=p_rental_id for update;
 if exists(select 1 from external_payment_cancellations where id=p_id) then raise exception 'This payment was cancelled. Start a new payment.'; end if;
 select * into receipt from external_payment_receipts where id=p_id for update;
 if found then
  if receipt.rental_id<>p_rental_id or receipt.request is distinct from p_request then raise exception 'Payment key already used for another request.'; end if;
  if receipt.status in ('posted','refunded') then return receipt.result; end if;
  if receipt.status='cancelled' then raise exception 'This recording was cancelled. Start a new payment.'; end if;
  return receipt.result;
 end if;
 if r.checkout_creation_token is not null then raise exception 'Initial Stripe checkout is being created. Resume it before recording external funds.'; end if;
 if r.status='cancelled' then raise exception 'Cancelled rentals cannot receive payment.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.id and status='pending') or
 exists(select 1 from external_toll_receipts where rental_id=r.id and status='pending') then raise exception 'Resume or cancel the pending payment first.'; end if;
 if p_request->>'paymentMethod' is null or p_request->>'paymentMethod' not in ('cash','terminal','card','cash_app','bank_transfer','other') then raise exception 'Choose a payment method.'; end if;
 if p_request->>'receivedDate' is null or (p_request->>'receivedDate')::date>(now() at time zone 'America/New_York')::date then raise exception 'Choose a received date no later than today.'; end if;
 if nullif(p_request->>'receivedTime','') is not null and
 ((p_request->>'receivedDate')::date+ (p_request->>'receivedTime')::time)>(now() at time zone 'America/New_York') then raise exception 'Received time cannot be in the future.'; end if;
 if length(coalesce(p_request->>'notes',''))>2000 or length(coalesce(p_request->>'reference',''))>120 then raise exception 'Payment notes or reference are too long.'; end if;
 select coalesce(array_agg((e->>'id')::uuid order by e->>'id'),'{}'),count(distinct e->>'id') into ids,n from jsonb_array_elements(p_request->'charges') e;
 if n<>cardinality(ids) or array_position(ids,null) is not null then raise exception 'Choose distinct charges.'; end if;
 perform 1 from rental_charge_items where id=any(ids) order by id for update;
 select count(*),coalesce(sum(round(public.rentmect_charge_remaining_amount(rental_charge_items)*100)),0) into n,total from rental_charge_items
 where id=any(ids) and rental_id=r.id and user_id=r.user_id and not included_in_initial_payment
 and charge_type not in ('rental_amendment','rental_installment') and status in ('pending','failed','checkout_open')
 and payment_receipt_id is null and external_toll_receipt_id is null and checkout_creation_token is null
 and not (admin_charge_attempted_at is not null and stripe_payment_intent_id is null);
 if n<>cardinality(ids) then raise exception 'A charge changed or is being collected. Refresh the rental.'; end if;
 for item in select e from jsonb_array_elements(p_request->'charges') e loop
  if not exists(select 1 from rental_charge_items where id=(item->>'id')::uuid and round(public.rentmect_charge_remaining_amount(rental_charge_items)*100)=(item->>'expectedRemainingCents')::integer and (item->>'amountCents')::integer>0 and (item->>'amountCents')::integer<=(item->>'expectedRemainingCents')::integer) then raise exception 'A selected amount changed.'; end if;
 end loop;
 due:=round(greatest(0,rentmect_rental_invoice_total(r.id)-rentmect_rental_net_paid_amount(r.id))*100)::integer;
 if rent_cents>due or (rent_cents>0 and (p_request->>'expectedRentalDueCents')::integer is distinct from due) then raise exception 'Rental balance changed. Review the payment again.'; end if;
 select coalesce(sum((e->>'amountCents')::integer),0) into total from jsonb_array_elements(p_request->'charges') e;
 if total+rent_cents+credit_cents is distinct from (p_request->>'amountCents')::integer then raise exception 'Allocations must equal the received amount.'; end if;
 -- Snapshot all rental collection representations as well as the selected extras.
 select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]') into paths from rental_charge_items c where
 c.id=any(ids) or (rent_cents>0 and c.rental_id=r.id and c.charge_type in ('rental_amendment','rental_installment') and c.status in ('pending','checkout_open','failed'));
 if rent_cents>0 and r.paid_at is null then paths:=paths||jsonb_build_array(jsonb_build_object('stripe_checkout_session_id',r.stripe_checkout_session_id,'stripe_payment_intent_id',r.stripe_payment_intent_id)); end if;
 if exists(select 1 from jsonb_array_elements(paths) e where nullif(e->>'checkout_creation_token','') is not null or (nullif(e->>'admin_charge_attempted_at','') is not null and nullif(e->>'stripe_payment_intent_id','') is null) or
 (e->>'status'='checkout_open' and nullif(e->>'stripe_checkout_session_id','') is null and nullif(e->>'stripe_payment_intent_id','') is null)) then raise exception 'A card payment is starting. Refresh before recording payment.'; end if;
 insert into external_payment_receipts(id,rental_id,actor_id,request,amount_cents,rental_amount_cents,payment_method,received_date,received_time,reference,notes,allocation_version,funding_kind,credit_amount_cents)
 values(p_id,r.id,p_actor_id,p_request,(p_request->>'amountCents')::integer,rent_cents,p_request->>'paymentMethod',case when funding='credit' then (now() at time zone 'America/New_York')::date else (p_request->>'receivedDate')::date end,case when funding='credit' then (now() at time zone 'America/New_York')::time else nullif(p_request->>'receivedTime','')::time end,nullif(trim(p_request->>'reference'),''),nullif(trim(p_request->>'notes'),''),2,funding,credit_cents);
 insert into external_payment_allocations select p_id,c.id,(e->>'amountCents')::integer,to_jsonb(c) from jsonb_array_elements(p_request->'charges') e join rental_charge_items c on c.id=(e->>'id')::uuid;
 if funding='credit' then
  needed:=(p_request->>'amountCents')::integer;
  for source in select x.id,x.credit_amount_cents-coalesce((select sum(a.amount_cents) from customer_credit_applications a join external_payment_receipts used on used.id=a.receipt_id where a.source_receipt_id=x.id and used.status in ('pending','posted')),0) as available
    from external_payment_receipts x where x.rental_id=r.id and x.status='posted' and x.credit_amount_cents>0 and x.funding_kind<>'credit' order by x.posted_at,x.id for update of x loop
   take_cents:=least(needed,source.available);
   if take_cents>0 then insert into customer_credit_applications values(source.id,p_id,take_cents); needed:=needed-take_cents; end if;
   exit when needed=0;
  end loop;
  if needed<>0 then raise exception 'Available customer credit changed. Review the payment again.'; end if;
 end if;
 -- Collection paths are stored separately from the client's immutable request.
 update external_payment_receipts set result=jsonb_build_object('status','pending','receiptId',p_id,'charges',paths) where id=p_id;
 return jsonb_build_object('status','pending','receiptId',p_id,'charges',paths);
end $$;

create function public.service_finish_external_payment(p_id uuid,p_actor_id uuid,p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare receipt external_payment_receipts%rowtype; settlement jsonb; paid_id uuid; prior text; v_result jsonb; a record; prior_deposits uuid[];
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=p_id) for update;
 select * into strict receipt from external_payment_receipts where id=p_id for update;
 if receipt.allocation_version=1 then return service_finish_external_payment_v1(p_id,p_actor_id,p_cancel); end if;
 if receipt.rental_amount_cents>0 or receipt.credit_amount_cents>0 or receipt.funding_kind='credit' then perform require_external_payment_actor(p_actor_id,'payment.collect'); end if;
 if jsonb_array_length(receipt.request->'charges')>0 then perform require_external_payment_actor(p_actor_id,'charge.manage'); end if;
 if receipt.status in ('posted','refunded') then return receipt.result; end if;
 if receipt.status='cancelled' then
  if p_cancel then return jsonb_build_object('status','cancelled','receiptId',p_id); end if;
  raise exception 'This recording was cancelled.';
 end if;
 if receipt.funding_kind='stripe' then raise exception 'Provider confirmation is required.'; end if;
 if p_cancel then
  update external_payment_receipts set status='cancelled' where id=p_id;
  insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(receipt.rental_id,p_actor_id,'external_payment_cancelled',jsonb_build_object('receipt_id',p_id));
  return jsonb_build_object('status','cancelled','receiptId',p_id);
 end if;
 prior:=current_setting('rentmect.external_payment_write',true);
 perform set_config('rentmect.external_payment_write','on',true);
 for a in select x.*,c.status,c.rental_id,round(rentmect_charge_remaining_amount(c)*100)::integer as remaining from external_payment_allocations x join rental_charge_items c on c.id=x.charge_id where x.receipt_id=p_id order by c.id for update of c loop
  if a.rental_id<>receipt.rental_id or a.status not in ('pending','failed','checkout_open') or a.amount_cents>a.remaining then raise exception 'Payment allocations changed.'; end if;
  update rental_charge_items set allocation_managed=true,allocated_payment_cents=allocated_payment_cents+a.amount_cents,
   status=case when a.amount_cents=a.remaining then 'paid' else 'pending' end,
   payment_provider=case when allocated_deposit_cents>0 then 'deposit' else 'local' end,payment_amount_cents=allocated_payment_cents+a.amount_cents,payment_currency='usd',paid_at=now(),
   stripe_checkout_session_id=null,stripe_payment_intent_id=null,last_admin_charge_error=null,updated_at=now()
   where id=a.charge_id;
 end loop;
 if receipt.rental_amount_cents>0 then
  select coalesce(array_agg(id),'{}') into prior_deposits from rental_deposit_allocations where holder_rental_id=receipt.rental_id;
  update rental_charge_items set status='waived',stripe_checkout_session_id=null,stripe_payment_intent_id=null,updated_at=now()
   where rental_id=receipt.rental_id and charge_type='rental_installment' and status in ('pending','failed','checkout_open');
  settlement:=record_admin_rental_balance_payment(receipt.rental_id,receipt.rental_amount_cents/100.0,receipt.payment_method,receipt.reference,p_actor_id);
  paid_id:=(settlement->'payment'->>'id')::uuid;
  if paid_id is null then raise exception 'Rental settlement did not return its payment record.'; end if;
  insert into external_payment_allocations select p_id,id,receipt.rental_amount_cents,to_jsonb(c) from rental_charge_items c where id=paid_id;
  update rental_charge_items set flex_payment_receipt_id=p_id,payment_received_date=receipt.received_date,payment_received_time=receipt.received_time where id=paid_id;
  update rental_deposit_allocations set flex_payment_receipt_id=p_id where holder_rental_id=receipt.rental_id and not(id=any(prior_deposits));
 end if;
 if coalesce((select sum(amount_cents) from external_payment_allocations where receipt_id=p_id),0)+receipt.credit_amount_cents<>receipt.amount_cents then raise exception 'Receipt allocation mismatch.'; end if;
 update external_payment_receipts set status='posted',posted_at=now() where id=p_id;
 v_result:=jsonb_build_object('status','posted','receiptId',p_id,'amountCents',receipt.amount_cents,'rentalAmountCents',receipt.rental_amount_cents,
  'creditAmountCents',receipt.credit_amount_cents,'availableCreditCents',rental_available_credit_cents(receipt.rental_id),'funding',receipt.funding_kind,
  'balanceDue',greatest(0,rentmect_rental_invoice_total(receipt.rental_id)-rentmect_rental_net_paid_amount(receipt.rental_id)));
 update external_payment_receipts r set result=v_result where r.id=p_id;
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(receipt.rental_id,p_actor_id,
  case when receipt.funding_kind='credit' then 'customer_credit_applied' else 'external_payment_posted' end,jsonb_build_object('receipt_id',p_id,'request',receipt.request,'result',v_result));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
 return v_result;
end $$;

create function public.service_cancel_flexible_payment(p_id uuid,p_rental_id uuid,p_actor_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare receipt external_payment_receipts%rowtype;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 begin perform require_external_payment_actor(p_actor_id,'payment.collect');
 exception when others then perform require_external_payment_actor(p_actor_id,'charge.manage'); end;
 perform 1 from rentals where id=p_rental_id for update;
 if not found or p_id is null then raise exception 'Rental and payment key required.'; end if;
 select * into receipt from external_payment_receipts where id=p_id for update;
 if found then
  if receipt.rental_id<>p_rental_id then raise exception 'Payment belongs to another rental.'; end if;
  return service_finish_external_payment(p_id,p_actor_id,true);
 end if;
 if exists(select 1 from external_payment_cancellations where id=p_id and rental_id<>p_rental_id) then raise exception 'Payment key belongs to another rental.'; end if;
 insert into external_payment_cancellations(id,rental_id,actor_id) values(p_id,p_rental_id,p_actor_id) on conflict(id) do nothing;
 return jsonb_build_object('status','cancelled','receiptId',p_id);
end $$;
revoke all on function public.service_cancel_flexible_payment(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_cancel_flexible_payment(uuid,uuid,uuid) to service_role;

-- Legacy mutations cannot overwrite partial receipts or refund allocated rental money.
create function public.guard_flexible_payment_allocations() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if current_setting('rentmect.external_payment_write',true)='on' then return new; end if;
 if tg_table_name='rental_deposit_allocations' then
  if tg_op='INSERT' then
   if new.flex_payment_receipt_id is not null then raise exception 'Use Receive Payment to link a deposit source.'; end if;
  elsif new.flex_payment_receipt_id is distinct from old.flex_payment_receipt_id then raise exception 'Deposit receipt sources are immutable.';
  end if;
  return new;
 end if;
 if tg_table_name='rental_external_payment_actions' then
  if exists(select 1 from rental_charge_items where id=new.payment_charge_id and flex_payment_receipt_id is not null) then raise exception 'Use the receipt refund action for allocated payments.'; end if;
  return new;
 end if;
 if tg_op='INSERT' then
  if new.allocation_managed or new.allocated_payment_cents<>0 or new.allocated_deposit_cents<>0 or new.allocated_waiver_cents<>0 or new.flex_payment_receipt_id is not null then raise exception 'Use Receive Payment to create allocation evidence.'; end if;
  return new;
 end if;
 if tg_op='DELETE' then
  if old.allocation_managed or old.flex_payment_receipt_id is not null then raise exception 'Allocated payment history cannot be deleted.'; end if;
  return old;
 end if;
 if new.allocated_deposit_cents is distinct from old.allocated_deposit_cents or new.allocated_waiver_cents is distinct from old.allocated_waiver_cents or new.allocation_managed is distinct from old.allocation_managed or new.allocated_payment_cents is distinct from old.allocated_payment_cents or new.flex_payment_receipt_id is distinct from old.flex_payment_receipt_id then
  raise exception 'Use Receive Payment to change allocations.';
 end if;
 if old.flex_payment_receipt_id is not null and
  (to_jsonb(new)-array['name','description','updated_at']) is distinct from (to_jsonb(old)-array['name','description','updated_at']) then
  raise exception 'Use the receipt correction or refund action for this allocated payment.';
 end if;
 if old.allocation_managed and new.status=old.status and
  (new.payment_provider,new.payment_amount_cents,new.paid_at,new.stripe_payment_intent_id) is distinct from
  (old.payment_provider,old.payment_amount_cents,old.paid_at,old.stripe_payment_intent_id) then
  raise exception 'Use Receive Payment to change collection evidence.';
 end if;
 if old.allocation_managed or old.flex_payment_receipt_id is not null then
  if (new.checkout_creation_token is not null and new.checkout_creation_token is distinct from old.checkout_creation_token)
    or new.admin_charge_attempts is distinct from old.admin_charge_attempts
    or (new.external_toll_receipt_id is not null and new.external_toll_receipt_id is distinct from old.external_toll_receipt_id)
    or (new.stripe_checkout_session_id is not null and new.stripe_checkout_session_id is distinct from old.stripe_checkout_session_id) then
   raise exception 'Use Receive Payment for this allocated charge. Legacy collection cannot charge its original amount.';
  end if;
  if (new.total_amount,new.amount,new.tax_amount,new.rental_id,new.user_id) is distinct from (old.total_amount,old.amount,old.tax_amount,old.rental_id,old.user_id) then raise exception 'An allocated charge cannot be repriced or reassigned.'; end if;
  if old.status<>new.status then
   if new.status='waived' and old.status in ('pending','failed','checkout_open') then
    new.allocated_waiver_cents:=round(old.total_amount*100)::integer-old.allocated_payment_cents-old.allocated_deposit_cents;
   elsif new.status='paid' and new.payment_provider='deposit' then
    new.allocated_deposit_cents:=(select coalesce(sum(round(amount*100)),0)::integer from rental_deposit_charge_applications where charge_id=old.id);
    if new.allocated_deposit_cents+old.allocated_payment_cents+old.allocated_waiver_cents<>round(old.total_amount*100) then raise exception 'Deposit applications do not settle the remaining charge.'; end if;
   else raise exception 'Use Receive Payment for the remaining allocated charge balance.'; end if;
  end if;
 end if;
 return new;
end $$;
create trigger flexible_charge_guard before insert or update or delete on public.rental_charge_items for each row execute function public.guard_flexible_payment_allocations();
create trigger flexible_deposit_source_guard before insert or update on public.rental_deposit_allocations for each row execute function public.guard_flexible_payment_allocations();
create trigger flexible_refund_guard before insert or update on public.rental_external_payment_actions for each row execute function public.guard_flexible_payment_allocations();

-- A whole-receipt reversal cannot also return money already used by the deposit
-- lifecycle. Keep this eligibility check visible before staff return any funds.
-- Credit-funded deposit reversals need their own non-cash source accounting;
-- the legacy rental refund helper records an external cash return.
create function public.flexible_receipt_refund_block_reason(p_receipt_id uuid) returns text
language plpgsql stable security invoker set search_path=public as $$
declare r external_payment_receipts%rowtype; rental_cents integer; net_paid numeric; invoice_without_deposit numeric; deposit numeric;
begin
 if auth.uid() is null or not is_admin() or not (rentmect_has_permission('payment.collect') or rentmect_has_permission('charge.manage') or rentmect_has_permission('tab.payments') or rentmect_has_permission('payment.refund')) then raise exception 'Payment access required.'; end if;
 select * into r from external_payment_receipts where id=p_receipt_id;
 if not found then return 'Receipt not found.'; end if;
 if r.allocation_version<>2 or r.status<>'posted' then return null; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.rental_id and status='pending') then return 'Resolve the pending payment first.'; end if;
 if exists(select 1 from customer_credit_applications ca join external_payment_receipts used on used.id=ca.receipt_id where ca.source_receipt_id=r.id and used.status in ('posted','pending')) then return 'This receipt has credit in use. Reverse those credit applications before refunding it.'; end if;
 select coalesce(sum(a.amount_cents),0) into rental_cents from external_payment_allocations a join rental_charge_items c on c.id=a.charge_id where a.receipt_id=r.id and c.charge_type='rental_amendment';
 if rental_cents=0 then return null; end if;
 if exists(select 1 from rental_deposit_allocations d where d.source_rental_id=r.rental_id and d.payment_provider='local' and
   (d.amount_released>0 or d.amount_applied>0 or d.holder_rental_id<>r.rental_id or d.status='release_pending')) then
  return 'This rental deposit has already been used, returned, transferred, or reserved for return. A full receipt refund requires deposit reconciliation first; do not return this receipt amount again.';
 end if;
 if r.funding_kind='credit' and exists(select 1 from rental_deposit_allocations d where d.source_rental_id=r.rental_id and d.holder_rental_id=r.rental_id and d.payment_provider='local' and d.amount_held>d.amount_released+d.amount_applied) then
  net_paid:=rentmect_rental_net_paid_amount(r.rental_id);
  select coalesce(security_deposit,0) into deposit from rentals where id=r.rental_id;
  invoice_without_deposit:=greatest(0,rentmect_rental_invoice_total(r.rental_id)-deposit);
  if least(deposit,greatest(0,net_paid-invoice_without_deposit))>least(deposit,greatest(0,net_paid-rental_cents/100.0-invoice_without_deposit)) then
   return 'This credit application funds a held deposit. Deposit credit reversal must be reconciled before this application can be reversed; no cash refund should be recorded.';
  end if;
 end if;
 return null;
end $$;
revoke all on function public.flexible_receipt_refund_block_reason(uuid) from public,anon;
grant execute on function public.flexible_receipt_refund_block_reason(uuid) to authenticated,service_role;

create function public.admin_flexible_payment_state(p_rental_id uuid) returns jsonb
language plpgsql stable security invoker set search_path=public as $$
begin
 if auth.uid() is null or not is_admin() or not (rentmect_has_permission('payment.collect') or rentmect_has_permission('charge.manage') or rentmect_has_permission('tab.payments')) then raise exception 'Payment access required.'; end if;
 return jsonb_build_object('version',2,'availableCreditCents',rental_available_credit_cents(p_rental_id),
  'receipts',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('refund_block_reason',flexible_receipt_refund_block_reason(r.id)) order by r.created_at desc) from external_payment_receipts r where r.rental_id=p_rental_id),'[]'),
  'allocations',coalesce((select jsonb_agg(a) from external_payment_allocations a join external_payment_receipts r on r.id=a.receipt_id where r.rental_id=p_rental_id),'[]'));
end $$;

create function public.admin_refund_external_payment(p_receipt_id uuid,p_reason text,p_reference text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r external_payment_receipts%rowtype; a record; prior text; v_result jsonb; blocked text;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('payment.refund'),false) then raise exception 'Refund permission required.'; end if;
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=p_receipt_id) for update;
 select * into strict r from external_payment_receipts where id=p_receipt_id for update;
 if r.allocation_version=1 then return admin_refund_external_payment_v1(p_receipt_id,p_reason,p_reference); end if;
 if r.status='refunded' then return r.result; end if;
 if r.status<>'posted' or r.funding_kind='stripe' then raise exception 'Only posted external receipts or credit applications can use this action.'; end if;
 if length(trim(coalesce(p_reason,'')))<5 then raise exception 'Provide a refund reason.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.rental_id and status='pending') then raise exception 'Resolve the pending payment first.'; end if;
 if exists(select 1 from customer_credit_applications ca join external_payment_receipts used on used.id=ca.receipt_id where ca.source_receipt_id=r.id and used.status in ('posted','pending')) then raise exception 'This receipt has credit in use. Reverse those credit applications before refunding it.'; end if;
 perform 1 from rental_deposit_allocations where source_rental_id=r.rental_id order by id for update;
 blocked:=flexible_receipt_refund_block_reason(r.id);
 if blocked is not null then raise exception '%',blocked; end if;
 prior:=current_setting('rentmect.external_payment_write',true); perform set_config('rentmect.external_payment_write','on',true);
 for a in select x.*,c.charge_type,c.allocated_payment_cents,c.allocated_waiver_cents,c.total_amount from external_payment_allocations x join rental_charge_items c on c.id=x.charge_id where x.receipt_id=r.id order by c.id for update of c loop
  if a.charge_type='rental_amendment' then
   perform admin_adjust_external_rental_payment(r.rental_id,a.charge_id,'refund',null,p_reference,p_reason);
  else
   update rental_charge_items set allocated_payment_cents=allocated_payment_cents-a.amount_cents,
    payment_amount_cents=allocated_payment_cents-a.amount_cents,
    status=case when round(total_amount*100)<=allocated_payment_cents-a.amount_cents+allocated_waiver_cents+allocated_deposit_cents then 'waived' else 'pending' end,updated_at=now()
    where id=a.charge_id;
  end if;
 end loop;
 v_result:=r.result||jsonb_build_object('status','refunded');
 update external_payment_receipts set status='refunded',refunded_at=now(),result=v_result where id=r.id;
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(r.rental_id,auth.uid(),'allocated_receipt_refunded',jsonb_build_object('receipt_id',r.id,'reason',p_reason,'reference',p_reference,'funding',r.funding_kind));
 perform set_config('rentmect.external_payment_write',coalesce(prior,''),true);
 return v_result;
end $$;
revoke all on function public.service_prepare_external_payment(uuid,uuid,uuid,jsonb),public.service_finish_external_payment(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.service_prepare_external_payment(uuid,uuid,uuid,jsonb),public.service_finish_external_payment(uuid,uuid,boolean) to service_role;
revoke all on function public.admin_flexible_payment_state(uuid),public.admin_refund_external_payment(uuid,text,text) from public,anon;
grant execute on function public.admin_flexible_payment_state(uuid),public.admin_refund_external_payment(uuid,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
