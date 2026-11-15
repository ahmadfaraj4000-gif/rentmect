-- Unified return: deposits plus source-backed credit, with durable refund reservations.
begin;
set local lock_timeout='5s';
create table public.rental_return_credit_sources(
 review_id uuid not null, source_receipt_id uuid not null references public.external_payment_receipts(id),
 rental_id uuid not null references public.rentals(id), applied_cents bigint not null check(applied_cents>=0),
 refund_cents bigint not null check(refund_cents>=0), provider text not null check(provider in ('stripe','external')),
 payment_method text, stripe_payment_intent_id text, stripe_refund_id text unique,
 status text not null check(status in ('reserved','pending','succeeded','failed','canceled','requires_action')),
 payout_method text, payout_reference text, returned_at timestamptz, created_at timestamptz not null default now(),
 primary key(review_id,source_receipt_id),check(applied_cents+refund_cents>0));
alter table public.rental_return_credit_sources add foreign key(review_id) references public.deposit_review_settlements(id) deferrable initially deferred;
create table public.rental_return_credit_applications(
 review_id uuid not null,source_receipt_id uuid not null,charge_id uuid not null references public.rental_charge_items(id),
 amount_cents bigint not null check(amount_cents>0),primary key(review_id,source_receipt_id,charge_id),
 foreign key(review_id,source_receipt_id) references public.rental_return_credit_sources(review_id,source_receipt_id));
alter table public.rental_return_credit_sources enable row level security;
alter table public.rental_return_credit_applications enable row level security;
revoke all on public.rental_return_credit_sources,public.rental_return_credit_applications from public,anon,authenticated;
grant all on public.rental_return_credit_sources,public.rental_return_credit_applications to service_role;
grant select on public.rental_return_credit_sources to authenticated;
create policy staff_return_credit_read on public.rental_return_credit_sources for select to authenticated using(public.is_admin() and (public.rentmect_has_permission('deposit.resolve') or public.rentmect_has_permission('payment.refund') or public.rentmect_has_permission('payment.collect') or public.rentmect_has_permission('tab.payments')));
create function public.return_credit_available_cents(p_source uuid) returns bigint language sql stable security definer set search_path=public as $$
 select greatest(0,r.credit_amount_cents
 -coalesce((select sum(a.amount_cents) from customer_credit_applications a join external_payment_receipts used on used.id=a.receipt_id where a.source_receipt_id=r.id and used.status in ('pending','posted')),0)
 -coalesce((select sum(s.applied_cents+s.refund_cents) from rental_return_credit_sources s where s.source_receipt_id=r.id),0))
 from external_payment_receipts r where r.id=p_source and r.status='posted' and r.funding_kind<>'credit'
$$;
revoke all on function public.return_credit_available_cents(uuid) from public,anon,authenticated;
grant execute on function public.return_credit_available_cents(uuid) to service_role;
create or replace function public.rental_available_credit_cents(p_rental_id uuid) returns bigint language sql stable security definer set search_path=public as $$
 select coalesce(sum(public.return_credit_available_cents(id)),0) from external_payment_receipts where rental_id=p_rental_id and (auth.role()='service_role' or public.is_admin() or exists(select 1 from rentals where id=p_rental_id and user_id=auth.uid()))
$$;
do $$ declare f record; d text; begin
 for f in select oid from pg_proc where pronamespace='public'::regnamespace and proname like 'service_prepare_external_payment%' loop
  select pg_get_functiondef(f.oid) into d;
  d:=replace(d,'x.credit_amount_cents-coalesce((select sum(a.amount_cents) from customer_credit_applications a join external_payment_receipts used on used.id=a.receipt_id where a.source_receipt_id=x.id and used.status in (''pending'',''posted'')),0) as available','public.return_credit_available_cents(x.id) as available');
  execute d;
 end loop;
end $$;
-- Serialize against normal credit spending; guard the direct per-source allocator as well.
create function public.guard_return_credit_spending() returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform 1 from rentals where id=(select rental_id from external_payment_receipts where id=new.source_receipt_id) for update;
 if new.amount_cents>coalesce(return_credit_available_cents(new.source_receipt_id),0) then raise exception 'Credit is reserved for a return or has already been used.'; end if;
 return new;
end $$;
create trigger protect_return_credit_spending before insert on public.customer_credit_applications for each row execute function public.guard_return_credit_spending();
create function public.guard_return_credit_receipt() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from rental_return_credit_sources where source_receipt_id=old.id) then
  if tg_op='DELETE' or (to_jsonb(new)-array['result','updated_at']) is distinct from (to_jsonb(old)-array['result','updated_at']) then
   raise exception 'This receipt has credit in a return settlement. Reconcile that settlement before changing the receipt.';
  end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger protect_return_credit_receipt before update or delete on public.external_payment_receipts for each row execute function public.guard_return_credit_receipt();
-- Block whole-receipt refunds before a provider operation is started.
do $$ declare d text; begin
 select pg_get_functiondef('public.flexible_receipt_refund_block_reason(uuid)'::regprocedure) into d;
 if position('if r.allocation_version<>2' in d)=0 then raise exception 'Review receipt refund eligibility contract.'; end if;
 d:=replace(d,'if r.allocation_version<>2', 'if exists(select 1 from rental_return_credit_sources where source_receipt_id=r.id) then return ''Credit from this payment is already reserved or used in a return settlement.''; end if; if r.allocation_version<>2');
 execute d;
end $$;
create or replace function public.service_apply_deposit_review(p_id uuid,p_rental_id uuid,p_actor_id uuid,p_request jsonb,p_charges jsonb,p_allocations jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; saved deposit_review_settlements%rowtype; a rental_deposit_allocations%rowtype; c rental_charge_items%rowtype;
 ids uuid[]; selected_total numeric:=0; held numeric:=0; budget numeric; needed numeric; used numeric; applied numeric:=0; result jsonb; credit_source record; credit_total bigint:=0; credit_needed bigint; credit_used bigint; credit_left bigint; charge_used bigint;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform require_external_payment_actor(p_actor_id,'deposit.resolve');
 select * into strict r from rentals where id=p_rental_id for update;
 select * into saved from deposit_review_settlements where id=p_id;
 if found then
  if saved.rental_id<>p_rental_id or saved.request<>p_request then raise exception 'Deposit review key already used.'; end if;
  return saved.result;
 end if;
 if exists(select 1 from rental_return_credit_sources where rental_id=r.id and review_id<>p_id and status<>'succeeded') then raise exception 'Continue the saved return before starting another review.'; end if;
 if r.status<>'completed' or r.ending_mileage is null or r.inspection_completed_at is null then raise exception 'Complete the return inspection and record ending mileage before reviewing the deposit.'; end if;
 if length(trim(coalesce(p_request->>'reason','')))<1 then raise exception 'Enter a review reason.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.id and status='pending') then raise exception 'Finish or cancel the pending payment before settling the deposit.'; end if;
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(p_request->'chargeIds');
 if cardinality(ids)>0 then perform require_external_payment_actor(p_actor_id,'charge.manage'); end if;
 if cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then raise exception 'Select distinct charges.'; end if;
 perform 1 from rental_charge_items where rental_id=r.id and id=any(ids) order by id for update;
 if (select count(*) from rental_charge_items where rental_id=r.id and id=any(ids))<>cardinality(ids) then raise exception 'A charge was removed.'; end if;
 for c in select * from rental_charge_items where id=any(ids) order by id loop
  if c.included_in_initial_payment or c.charge_type in ('rental_amendment','rental_installment') or c.status not in ('pending','failed','checkout_open')
   or c.payment_receipt_id is not null or c.external_toll_receipt_id is not null or c.checkout_creation_token is not null
   or c.stripe_checkout_session_id is not null or c.stripe_payment_intent_id is not null or c.admin_charge_attempted_at is not null then raise exception 'A selected charge is being collected or is ineligible. Refresh it before using the deposit.'; end if;
  if not exists(select 1 from jsonb_array_elements(p_charges) x where x=to_jsonb(c)) then raise exception 'Charges changed during review.'; end if;
  selected_total:=selected_total+rentmect_charge_remaining_amount(c);
 end loop;
 perform 1 from rental_deposit_allocations where holder_rental_id=r.id order by id for update;
 for a in select * from rental_deposit_allocations where holder_rental_id=r.id and amount_held>amount_applied+amount_released order by id loop
  if not exists(select 1 from jsonb_array_elements(p_allocations) x where x=to_jsonb(a)) then raise exception 'Deposit sources changed during review.'; end if;
  if cardinality(ids)>0 and (a.status not in ('held','refund_due_inspection') or a.refund_id is not null or a.refund_reserved_amount is not null) then raise exception 'A deposit refund has already started. Reconcile it before deductions.'; end if;
  held:=held+a.amount_held-a.amount_applied-a.amount_released;
 end loop;
 if held is distinct from (p_request->>'expectedHeld')::numeric or selected_total is distinct from (p_request->>'expectedCharges')::numeric then raise exception 'Deposit or charge amounts changed. Review again.'; end if;
 if coalesce((p_request->>'includeCredit')::boolean,false) then
  perform require_external_payment_actor(p_actor_id,'payment.refund');
  perform 1 from external_payment_receipts where rental_id=r.id order by id for update;
  credit_total:=rental_available_credit_cents(r.id);
  if credit_total is distinct from (p_request->>'expectedCreditCents')::bigint then raise exception 'Available credit changed. Review again.'; end if;
 end if;
 budget:=least(held,selected_total);
 perform set_config('rentmect.external_payment_write','on',true);
 perform set_config('rentmect.deposit_review_write','on',true);
 for c in select * from rental_charge_items where id=any(ids) order by id loop
  needed:=least(budget,rentmect_charge_remaining_amount(c)); used:=needed;
  for a in select * from rental_deposit_allocations where holder_rental_id=r.id and amount_held>amount_applied+amount_released
    order by (payment_provider='local') desc,id loop
   exit when needed<=0;
   insert into rental_deposit_charge_applications(rental_id,allocation_id,charge_id,amount,reason,actor_id)
    values(r.id,a.id,c.id,least(needed,a.amount_held-a.amount_applied-a.amount_released),p_request->>'reason',p_actor_id);
   update rental_deposit_allocations set amount_applied=amount_applied+least(needed,a.amount_held-a.amount_applied-a.amount_released),
    status=case when amount_applied+amount_released+least(needed,a.amount_held-a.amount_applied-a.amount_released)=amount_held then 'released' else status end where id=a.id;
   needed:=greatest(0,needed-(a.amount_held-a.amount_applied-a.amount_released));
  end loop;
  if used>0 then
   update rental_charge_items set allocation_managed=true,allocated_deposit_cents=allocated_deposit_cents+round(used*100)::integer,
    status=case when used=rentmect_charge_remaining_amount(c) then 'paid' else 'pending' end,
    payment_provider='deposit',paid_at=now(),payment_amount_cents=allocated_payment_cents,updated_at=now() where id=c.id;
   budget:=budget-used;applied:=applied+used;
  end if;
 end loop;
 -- Reserve each credit source and allocate only the selected charge remainder.
 credit_needed:=least(credit_total,round((selected_total-applied)*100)::bigint);
 for credit_source in select x.*,public.return_credit_available_cents(x.id) as available from external_payment_receipts x
   where x.rental_id=r.id and x.status='posted' and x.funding_kind<>'credit' and x.credit_amount_cents>0
   order by x.id loop
  exit when not coalesce((p_request->>'includeCredit')::boolean,false);
  if credit_source.available<=0 then continue; end if;
  if credit_source.funding_kind='stripe' and credit_source.stripe_payment_intent_id is null then raise exception 'Credit has no original Stripe payment. Reconcile its source first.'; end if;
  credit_used:=least(credit_needed,credit_source.available);credit_left:=credit_used;
  insert into rental_return_credit_sources(review_id,source_receipt_id,rental_id,applied_cents,refund_cents,provider,payment_method,stripe_payment_intent_id,status)
   values(p_id,credit_source.id,r.id,credit_used,credit_source.available-credit_used,credit_source.funding_kind,credit_source.payment_method,credit_source.stripe_payment_intent_id,
     case when credit_source.available=credit_used then 'succeeded' else 'reserved' end);
  for c in select * from rental_charge_items where id=any(ids) order by id for update loop
   exit when credit_left<=0;
   charge_used:=least(credit_left,round(rentmect_charge_remaining_amount(c)*100)::bigint);
   if charge_used<=0 then continue; end if;
   insert into rental_return_credit_applications(review_id,source_receipt_id,charge_id,amount_cents) values(p_id,credit_source.id,c.id,charge_used);
   update rental_charge_items set allocation_managed=true,allocated_payment_cents=allocated_payment_cents+charge_used,
    payment_amount_cents=allocated_payment_cents+charge_used,
    status=case when charge_used=round(rentmect_charge_remaining_amount(c)*100) then 'paid' else 'pending' end,
    payment_provider=case when allocated_deposit_cents>0 then 'deposit' else 'local' end,paid_at=now(),updated_at=now() where id=c.id;
   credit_left:=credit_left-charge_used;
  end loop;
  credit_needed:=credit_needed-credit_used;
 end loop;
 perform refresh_rental_deposit_summary(r.id);
 update rentals set deposit_review_approved_at=now(),deposit_review_note=p_request->>'reason',deposit_review_follow_up_at=null where id=r.id;
 result:=jsonb_build_object('applied',least(selected_total,held+credit_total/100.0),'depositApplied',applied,'remaining',greatest(0,held+credit_total/100.0-selected_total));
 insert into deposit_review_settlements values(p_id,r.id,p_actor_id,p_request,result,now());
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(r.id,p_actor_id,'deposit_review_approved',result||jsonb_build_object('request',p_request));
 perform set_config('rentmect.external_payment_write','',true);perform set_config('rentmect.deposit_review_write','',true);
 return result;
end $$;

create function public.service_return_credit_sources(p_rental_id uuid) returns table(source_receipt_id uuid,stripe_payment_intent_id text,available_cents bigint) language sql stable security definer set search_path=public as $$
 select r.id,r.stripe_payment_intent_id,public.return_credit_available_cents(r.id) from external_payment_receipts r
 where auth.role()='service_role' and r.rental_id=p_rental_id and r.funding_kind='stripe' and public.return_credit_available_cents(r.id)>0
$$;
revoke all on function public.service_return_credit_sources(uuid) from public,anon,authenticated;
grant execute on function public.service_return_credit_sources(uuid) to service_role;

create function public.admin_return_workspace(p_rental_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('deposit.resolve'),false) then raise exception 'Deposit resolution permission required.'; end if;
 select jsonb_build_object(
 'allocations',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('payment_method',p.payment_method,'reference',p.reference)) from rental_deposit_allocations a left join external_payment_receipts p on p.id=a.flex_payment_receipt_id where a.holder_rental_id=p_rental_id),'[]'::jsonb),
 'charges',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from rental_charge_items c where c.rental_id=p_rental_id and rentmect_charge_remaining_amount(c)>0 and c.charge_type not in ('rental_amendment','rental_installment')),'[]'::jsonb),
 'credits',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'remaining',return_credit_available_cents(p.id),'payment_provider',case when p.funding_kind='stripe' then 'stripe' else 'local' end,'payment_method',p.payment_method,'stripe_payment_intent_id',p.stripe_payment_intent_id)) from external_payment_receipts p where p.rental_id=p_rental_id and return_credit_available_cents(p.id)>0),'[]'::jsonb),
 'resume', (select jsonb_build_object('id',s.id,'request',s.request) from deposit_review_settlements s where s.rental_id=p_rental_id and (exists(select 1 from rental_return_credit_sources c where c.review_id=s.id and c.status<>'succeeded') or exists(select 1 from rental_deposit_allocations a where a.holder_rental_id=p_rental_id and a.amount_held>a.amount_applied+a.amount_released)) order by s.created_at desc limit 1)
 ) into result;
 return result;
end $$;
revoke all on function public.admin_return_workspace(uuid) from public,anon;
grant execute on function public.admin_return_workspace(uuid) to authenticated;

create function public.service_record_return_external(p_review_id uuid,p_actor_id uuid,p_method text,p_reference text,p_expected_cents bigint) returns void language plpgsql security definer set search_path=public as $$
declare rid uuid; blockers jsonb; total bigint; prior jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform require_external_payment_actor(p_actor_id,'deposit.resolve');
 perform require_external_payment_actor(p_actor_id,'payment.refund');
 if length(trim(coalesce(p_method,'')))<2 or length(p_method)>80 or length(coalesce(p_reference,''))>200 then raise exception 'Enter the external payout method.'; end if;
 select rental_id into strict rid from deposit_review_settlements where id=p_review_id;
 perform 1 from rentals where id=rid for update;
 select result->'externalReturn' into prior from deposit_review_settlements where id=p_review_id for update;
 if prior is not null then
  if prior->>'method' is distinct from trim(p_method) or prior->>'reference' is distinct from coalesce(p_reference,'') or (prior->>'amountCents')::bigint is distinct from p_expected_cents then raise exception 'External return is already recorded with different details.'; end if;
  return;
 end if;
 perform 1 from rental_deposit_allocations where holder_rental_id=rid order by id for update;
 select coalesce(sum(round((amount_held-amount_applied-amount_released)*100)),0) into total from rental_deposit_allocations where holder_rental_id=rid and payment_provider='local';
 total:=total+coalesce((select sum(refund_cents) from rental_return_credit_sources where review_id=p_review_id and provider='external' and status='reserved'),0);
 if total<=0 or total is distinct from p_expected_cents then raise exception 'External return amount changed. Review the remaining amount before recording a payout.'; end if;
 blockers:=rentmect_deposit_chain_release_blockers(rid);
 if jsonb_array_length(blockers)>0 then raise exception 'Resolve refund blockers before recording a payout: %',blockers; end if;
 perform set_config('rentmect.deposit_review_write','on',true);
 perform set_config('rentmect.external_payment_write','on',true);
 update rental_deposit_allocations set amount_released=amount_held-amount_applied,status='released',updated_at=now()
 where holder_rental_id=rid and payment_provider='local' and amount_held>amount_applied+amount_released;
 update rental_return_credit_sources set status='succeeded',payout_method=trim(p_method),payout_reference=p_reference,returned_at=now()
 where review_id=p_review_id and provider='external' and status='reserved';
 perform refresh_rental_deposit_summary(rid);
 update deposit_review_settlements set result=result||jsonb_build_object('externalReturn',jsonb_build_object('amountCents',total,'method',trim(p_method),'reference',coalesce(p_reference,''))) where id=p_review_id;
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(rid,p_actor_id,'external_return_recorded',jsonb_build_object('reviewId',p_review_id,'method',p_method,'reference',p_reference));
end $$;
revoke all on function public.service_record_return_external(uuid,uuid,text,text,bigint) from public,anon,authenticated;
grant execute on function public.service_record_return_external(uuid,uuid,text,text,bigint) to service_role;


-- Keep customer payment history and the paginated financial activity report in sync.
do $$ declare d text; begin
 select pg_get_functiondef('public.admin_flexible_payment_state(uuid)'::regprocedure) into d;
 if position('''version'',2,' in d)=0 then raise exception 'Review payment state contract.'; end if;
 d:=replace(d,'''version'',2,','''version'',2,''creditReturns'',coalesce((select jsonb_agg(s order by s.created_at desc) from rental_return_credit_sources s where s.rental_id=p_rental_id),''[]''::jsonb),');
 execute d;
 if to_regprocedure('public.admin_payment_activity_page(text,text,integer)') is not null then
  select pg_get_functiondef('public.admin_payment_activity_page(text,text,integer)'::regprocedure) into d;
  if position(' ), grouped as materialized (' in d)=0 then raise exception 'Review the financial activity report contract.'; end if;
  d:=replace(d,' ), grouped as materialized (',$union$
 union all
 select 'return-credit-'||s.review_id::text||'-'||s.source_receipt_id::text,s.rental_id,'refund',
 case when s.status='succeeded' then 'refunded' when s.status in ('failed','canceled') then 'failed' else 'pending' end,s.status,
 -s.refund_cents/100.0,case when s.status='succeeded' then -s.refund_cents/100.0 else 0 end,0::numeric,
 coalesce(s.returned_at,s.created_at),null::date,null::time,'Customer credit return · '||coalesce(s.payout_method,s.payment_method,s.provider),s.provider,false,null::text,s.stripe_refund_id
 from public.rental_return_credit_sources s where s.refund_cents>0
 ), grouped as materialized ($union$);
  execute d;
 end if;
end $$;

notify pgrst,'reload schema';
commit;
