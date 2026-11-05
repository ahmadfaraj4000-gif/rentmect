begin;
-- The receipt is a grouping/audit record. Revenue continues to come from the
-- existing paid charge rows, so it is never counted a second time.
create table public.external_toll_receipts (
 id uuid primary key,
 rental_id uuid not null references public.rentals(id),
 actor_id uuid not null references auth.users(id),
 request jsonb not null,
 amount_cents integer not null check(amount_cents > 0),
 payment_method text not null check(payment_method in ('cash','terminal','card','cash_app','bank_transfer','other')),
 received_date date not null,
 reference text,
 status text not null default 'pending' check(status in ('pending','posted','cancelled')),
 created_at timestamptz not null default now(),
 posted_at timestamptz,
 cancelled_at timestamptz,
 result jsonb
);
create unique index external_toll_one_pending_per_rental on public.external_toll_receipts(rental_id) where status='pending';
create table public.external_toll_receipt_allocations (
 receipt_id uuid not null references public.external_toll_receipts(id),
 charge_id uuid not null references public.rental_charge_items(id),
 amount_cents integer not null check(amount_cents > 0),
 snapshot jsonb not null,
 primary key(receipt_id,charge_id)
);
alter table public.rental_charge_items add column external_toll_receipt_id uuid references public.external_toll_receipts(id);
alter table public.rental_charge_items add column checkout_creation_token uuid;
alter table public.external_toll_receipts enable row level security;
alter table public.external_toll_receipt_allocations enable row level security;
revoke all on public.external_toll_receipts,public.external_toll_receipt_allocations from public,anon,authenticated;
grant select on public.external_toll_receipts,public.external_toll_receipt_allocations to authenticated;
grant all on public.external_toll_receipts,public.external_toll_receipt_allocations to service_role;
create policy staff_read_external_toll_receipts on public.external_toll_receipts for select to authenticated
 using(public.is_admin() and public.rentmect_has_permission('charge.manage'));
create policy staff_read_external_toll_allocations on public.external_toll_receipt_allocations for select to authenticated
 using(public.is_admin() and public.rentmect_has_permission('charge.manage'));

-- Freeze each selected charge before contacting Stripe. This also covers the
-- old single-payment, waiver, deposit and webhook writers without bypasses.
create function public.protect_external_toll_receipt_charge() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if current_setting('rentmect.external_toll_write',true)='on' then
  if tg_op='DELETE' then return old; end if; return new;
 end if;
 if tg_op='INSERT' then
  if new.external_toll_receipt_id is not null then raise exception 'Use the toll receipt workflow.'; end if;
  return new;
 end if;
 if old.external_toll_receipt_id is not null then
  -- An idempotent provider sync may update timestamps/descriptions, but it may
  -- never reopen, reprice, transfer, or recollect a reserved/settled charge.
  if tg_op='DELETE' then raise exception 'A toll receipt protects this charge from deletion.'; end if;
  if (to_jsonb(new)-'updated_at'-'description'-'name') is distinct from
     (to_jsonb(old)-'updated_at'-'description'-'name') then
   raise exception 'This toll belongs to an external payment receipt. Resume or cancel the pending receipt before changing it.';
  end if;
 elsif tg_op='UPDATE' and new.external_toll_receipt_id is not null then
  raise exception 'Use the toll receipt workflow.';
 end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger protect_external_toll_receipt_charge before insert or update or delete on public.rental_charge_items
 for each row execute function public.protect_external_toll_receipt_charge();

create function public.require_external_toll_actor(p_actor_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 if not exists(select 1 from public.profiles p where p.id=p_actor_id and p.role='admin' and
  (p.staff_role in ('owner','operations_manager') or (p.staff_role='employee' and coalesce(
   (select enabled from public.staff_permission_overrides where user_id=p.id and permission_key='charge.manage'),
   (select enabled from public.employee_permissions where permission_key='charge.manage'),false)))) then
  raise exception 'Charge management permission required.';
 end if;
end $$;

create function public.service_prepare_external_toll_receipt(p_id uuid,p_rental_id uuid,p_actor_id uuid,p_request jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; receipt public.external_toll_receipts%rowtype;
 c public.rental_charge_items%rowtype; ids uuid[]; total bigint; n integer; prior_setting text;
begin
 perform public.require_external_toll_actor(p_actor_id);
 if p_id is null or p_request is null or jsonb_typeof(p_request->'charges') is distinct from 'array' then
  raise exception 'Choose tolls and provide a request key.'; end if;
 select * into strict r from public.rentals where id=p_rental_id for update;
 select * into receipt from public.external_toll_receipts where id=p_id for update;
 if found then
  if receipt.rental_id<>p_rental_id or receipt.request is distinct from p_request then raise exception 'Request key already used for a different payment.'; end if;
  if receipt.status='cancelled' then raise exception 'This recording was cancelled. Start a new payment.'; end if;
  if receipt.status='posted' then return receipt.result; end if;
  return jsonb_build_object('status','pending','receiptId',receipt.id,'charges',
   (select jsonb_agg(snapshot order by charge_id) from public.external_toll_receipt_allocations where receipt_id=receipt.id));
 end if;
 if jsonb_array_length(p_request->'charges') not between 1 and 500 then raise exception 'Choose between 1 and 500 tolls.'; end if;
 select array_agg((e->>'id')::uuid order by e->>'id'),count(distinct e->>'id') into ids,n from jsonb_array_elements(p_request->'charges') e;
 if n<>cardinality(ids) or array_position(ids,null) is not null then raise exception 'Choose distinct tolls.'; end if;
 if (p_request->>'paymentMethod') is null or (p_request->>'paymentMethod') not in ('cash','terminal','card','cash_app','bank_transfer','other') then raise exception 'Choose a payment method.'; end if;
 if (p_request->>'receivedDate') is null or (p_request->>'receivedDate')::date > (now() at time zone 'America/New_York')::date then raise exception 'Choose a received date no later than today.'; end if;
 if length(coalesce(p_request->>'reference',''))>120 then raise exception 'Reference is too long.'; end if;
 perform 1 from public.rental_charge_items where id=any(ids) order by id for update;
 select count(*),sum(round(total_amount*100)::bigint) into n,total from public.rental_charge_items
  where id=any(ids) and rental_id=r.id and user_id=r.user_id and charge_type='toll'
  and not included_in_initial_payment and status in ('pending','failed','checkout_open')
  and external_toll_receipt_id is null and checkout_creation_token is null
  and not (admin_charge_attempted_at is not null and stripe_payment_intent_id is null);
 if n<>cardinality(ids) then raise exception 'A toll changed, is being collected, or is no longer eligible. Refresh the rental.'; end if;
 if (p_request->>'amountCents') is null or total<>(p_request->>'amountCents')::integer then raise exception 'Received amount must exactly match the selected toll total.'; end if;
 for c in select * from public.rental_charge_items where id=any(ids) order by id loop
  if not exists(select 1 from jsonb_array_elements(p_request->'charges') e where e->>'id'=c.id::text
   and (e->>'amountCents')::integer=round(c.total_amount*100)::integer) then raise exception 'A selected toll amount changed. Review it again.'; end if;
 end loop;
 insert into public.external_toll_receipts(id,rental_id,actor_id,request,amount_cents,payment_method,received_date,reference)
 values(p_id,r.id,p_actor_id,p_request,total,p_request->>'paymentMethod',(p_request->>'receivedDate')::date,nullif(trim(p_request->>'reference'),''));
 insert into public.external_toll_receipt_allocations(receipt_id,charge_id,amount_cents,snapshot)
 select p_id,ci.id,round(ci.total_amount*100)::integer,to_jsonb(ci) from public.rental_charge_items ci where ci.id=any(ids);
 prior_setting:=current_setting('rentmect.external_toll_write',true);
 perform set_config('rentmect.external_toll_write','on',true);
 update public.rental_charge_items set external_toll_receipt_id=p_id where id=any(ids);
 perform set_config('rentmect.external_toll_write',coalesce(prior_setting,''),true);
 return jsonb_build_object('status','pending','receiptId',p_id,'charges',
  (select jsonb_agg(snapshot order by charge_id) from public.external_toll_receipt_allocations where receipt_id=p_id));
end $$;

create function public.service_finish_external_toll_receipt(p_id uuid,p_actor_id uuid,p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare receipt public.external_toll_receipts%rowtype; v_result jsonb; prior_setting text; n integer;
begin
 perform public.require_external_toll_actor(p_actor_id);
 -- Use the same rental -> receipt -> charge lock order as preparation/deposits.
 perform 1 from public.rentals where id=(select rental_id from public.external_toll_receipts where id=p_id) for update;
 select * into strict receipt from public.external_toll_receipts where id=p_id for update;
 if receipt.status='posted' then return receipt.result; end if;
 if receipt.status='cancelled' then
  if p_cancel then return jsonb_build_object('status','cancelled','receiptId',p_id); end if;
  raise exception 'This recording was cancelled. No external payment was posted.';
 end if;
 perform 1 from public.rental_charge_items where external_toll_receipt_id=p_id order by id for update;
 prior_setting:=current_setting('rentmect.external_toll_write',true);
 perform set_config('rentmect.external_toll_write','on',true);
 if p_cancel then
  update public.rental_charge_items set external_toll_receipt_id=null where external_toll_receipt_id=p_id;
  update public.external_toll_receipts set status='cancelled',cancelled_at=now() where id=p_id;
  v_result:=jsonb_build_object('status','cancelled','receiptId',p_id);
 else
  -- Revalidate every allocation before mutating any paid state.
  if exists(select 1 from public.external_toll_receipt_allocations a left join public.rental_charge_items c on c.id=a.charge_id
    where a.receipt_id=p_id and (c.id is null or c.external_toll_receipt_id is distinct from p_id or
    c.status not in ('pending','failed','checkout_open') or c.rental_id<>receipt.rental_id or
    round(c.total_amount*100)::integer<>a.amount_cents or c.checkout_creation_token is not null)) then
   raise exception 'A selected toll changed. No payment was posted.';
  end if;
  update public.rental_charge_items set status='paid',payment_provider='local',
   payment_amount_cents=round(total_amount*100)::integer,payment_currency='usd',paid_at=now(),
   external_payment_method=receipt.payment_method,external_payment_reference=receipt.reference,
   external_payment_recorded_by=receipt.actor_id,stripe_checkout_session_id=null,stripe_payment_intent_id=null,
   last_admin_charge_error=null,updated_at=now() where external_toll_receipt_id=p_id;
  get diagnostics n=row_count;
  if n=0 or n<>(select count(*) from public.external_toll_receipt_allocations where receipt_id=p_id) then raise exception 'Receipt allocation mismatch.'; end if;
  v_result:=jsonb_build_object('status','posted','receiptId',p_id,'amountCents',receipt.amount_cents,'count',n);
  update public.external_toll_receipts set status='posted',posted_at=now(),result=v_result where id=p_id;
 end if;
 perform set_config('rentmect.external_toll_write',coalesce(prior_setting,''),true);
 insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
 select receipt.rental_id,r.user_id,p_actor_id,'external_toll_receipt_'||case when p_cancel then 'cancelled' else 'posted' end,
  jsonb_build_object('receipt_id',p_id,'amount_cents',receipt.amount_cents,'payment_method',receipt.payment_method,
   'received_date',receipt.received_date,'reference',receipt.reference,'allocations',
   (select jsonb_agg(jsonb_build_object('charge_id',charge_id,'amount_cents',amount_cents,'before',snapshot) order by charge_id)
    from public.external_toll_receipt_allocations where receipt_id=p_id)) from public.rentals r where r.id=receipt.rental_id;
 return v_result;
end $$;
revoke all on function public.require_external_toll_actor(uuid),public.service_prepare_external_toll_receipt(uuid,uuid,uuid,jsonb),public.service_finish_external_toll_receipt(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.service_prepare_external_toll_receipt(uuid,uuid,uuid,jsonb),public.service_finish_external_toll_receipt(uuid,uuid,boolean) to service_role;
commit;
