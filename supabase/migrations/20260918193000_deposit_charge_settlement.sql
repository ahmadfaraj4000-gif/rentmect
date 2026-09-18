-- Applied charges and actual refunds are distinct uses of the original capture.
-- Existing deposits default to zero applied; no financial records are migrated.
alter table public.rental_deposit_allocations
 add column amount_applied numeric(12,2) not null default 0,
 add column refund_reserved_amount numeric(12,2);
alter table public.rental_deposit_allocations
 drop constraint released_deposit_is_fully_returned,
 add constraint deposit_uses_within_capture check
  (amount_applied>=0 and amount_applied+amount_released<=amount_held),
 add constraint released_deposit_is_fully_settled check
  (status<>'released' or amount_released+amount_applied=amount_held),
 add constraint reserved_deposit_remainder check
  (refund_reserved_amount is null or (refund_reserved_amount>0 and refund_reserved_amount=amount_held-amount_applied));

create table public.rental_deposit_charge_applications (
 id uuid primary key default gen_random_uuid(),
 rental_id uuid not null references public.rentals(id) on delete restrict,
 allocation_id uuid not null references public.rental_deposit_allocations(id) on delete restrict,
 charge_id uuid not null unique references public.rental_charge_items(id) on delete restrict,
 amount numeric(12,2) not null check(amount>0),
 reason text not null check(length(trim(reason))>=5),
 actor_id uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.rental_deposit_charge_applications enable row level security;
revoke all on public.rental_deposit_charge_applications from public,anon,authenticated;
grant select on public.rental_deposit_charge_applications to authenticated;
grant all on public.rental_deposit_charge_applications to service_role;
create policy "Staff read deposit charge applications" on public.rental_deposit_charge_applications
 for select to authenticated using(public.is_admin() and public.rentmect_has_permission('reports.financial'));

create function public.protect_deposit_settlement() returns trigger
language plpgsql set search_path=public as $$
begin
 if TG_TABLE_NAME='rental_deposit_charge_applications' then
  raise exception 'Deposit charge applications are immutable audit records.';
 elsif TG_TABLE_NAME='rental_deposit_allocations' then
  if old.refund_reserved_amount is not null and
    (new.refund_reserved_amount is distinct from old.refund_reserved_amount or
     new.amount_applied<>old.amount_applied or new.amount_held<>old.amount_held) then
   raise exception 'A reserved deposit refund cannot be resized.';
  end if;
  if new.amount_applied<old.amount_applied then raise exception 'Applied deposit funds cannot be removed.'; end if;
  if old.amount_applied>0 and (new.holder_rental_id<>old.holder_rental_id or
    new.source_rental_id<>old.source_rental_id or new.payment_provider<>old.payment_provider or
    new.stripe_payment_intent_id is distinct from old.stripe_payment_intent_id or new.amount_held<>old.amount_held) then
   raise exception 'A deposit applied to charges cannot be transferred or replaced.';
  end if;
 elsif TG_TABLE_NAME='rentals' then
  if exists(select 1 from public.rental_deposit_charge_applications where rental_id=old.id) and
   (new.status<>old.status or new.security_deposit<>old.security_deposit or
    new.rental_total<>old.rental_total or new.tax_amount<>old.tax_amount or
    new.vehicle_id<>old.vehicle_id or new.user_id<>old.user_id) then
   raise exception 'This completed rental has a deposit settlement; reconcile it before changing the booking.';
  end if;
 elsif TG_TABLE_NAME='rental_charge_items' then
  if exists(select 1 from public.rental_deposit_charge_applications where charge_id=old.id) then
   if TG_OP='DELETE' then raise exception 'A charge paid from a deposit cannot be deleted.'; end if;
   if new.status<>'paid' or new.payment_provider is distinct from 'deposit' or
    new.total_amount<>old.total_amount or new.amount<>old.amount or new.tax_amount<>old.tax_amount or
    new.rental_id<>old.rental_id or new.charge_type<>old.charge_type or
    new.included_in_initial_payment is distinct from old.included_in_initial_payment or
    new.stripe_payment_intent_id is not null or new.stripe_checkout_session_id is not null or
    new.payment_amount_cents is distinct from 0 then
    raise exception 'A charge paid from a deposit cannot be collected, waived, or changed again.';
   end if;
  end if;
 end if;
 if TG_OP='DELETE' then return old; end if;
 return new;
end $$;
create trigger protect_deposit_application before update or delete on public.rental_deposit_charge_applications
 for each row execute function public.protect_deposit_settlement();
create trigger protect_deposit_allocation_settlement before update on public.rental_deposit_allocations
 for each row execute function public.protect_deposit_settlement();
create trigger protect_deposit_charge_settlement before update or delete on public.rental_charge_items
 for each row execute function public.protect_deposit_settlement();
create trigger protect_settled_rental before update on public.rentals
 for each row execute function public.protect_deposit_settlement();

create function public.check_deposit_application_total() returns trigger
language plpgsql security definer set search_path=public as $$
declare aid uuid; a public.rental_deposit_allocations%rowtype;
begin
 if TG_TABLE_NAME='rental_deposit_allocations' then aid:=new.id; else aid:=new.allocation_id; end if;
 select * into a from public.rental_deposit_allocations where id=aid;
 if a.amount_applied<>(select coalesce(sum(amount),0) from public.rental_deposit_charge_applications where allocation_id=aid) then
  raise exception 'Applied deposit total must match charge applications.';
 end if;
 if exists(select 1 from public.rental_deposit_charge_applications d join public.rental_charge_items c on c.id=d.charge_id
  where d.allocation_id=aid and (d.rental_id<>a.holder_rental_id or c.rental_id<>d.rental_id or
   c.status<>'paid' or c.payment_provider is distinct from 'deposit' or c.total_amount<>d.amount)) then
  raise exception 'Deposit applications must match settled charges on the same rental.';
 end if;
 return null;
end $$;
create constraint trigger check_applied_deposit_total after insert or update on public.rental_deposit_allocations
 deferrable initially deferred for each row execute function public.check_deposit_application_total();
create constraint trigger check_deposit_application after insert on public.rental_deposit_charge_applications
 deferrable initially deferred for each row execute function public.check_deposit_application_total();

-- Service-only entrypoint. Edge authenticates deposit.resolve AND charge.manage.
-- Restrict to one untouched, locally owned Stripe allocation and unopened charges.
create function public.service_apply_deposit_to_charges(
 p_rental_id uuid,p_charge_ids uuid[],p_expected_applied numeric,p_expected_refund numeric,p_actor_id uuid,p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; a public.rental_deposit_allocations%rowtype;
 c public.rental_charge_items%rowtype; total numeric; n integer; blockers jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 if p_actor_id is null or not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then
  raise exception 'An authenticated staff actor is required.';
 end if;
 if length(trim(coalesce(p_reason,'')))<5 then raise exception 'Enter a settlement reason of at least five characters.'; end if;
 if coalesce(cardinality(p_charge_ids),0)=0 or cardinality(p_charge_ids)<>(select count(distinct x) from unnest(p_charge_ids) x) then
  raise exception 'Choose distinct charges to pay from the deposit.';
 end if;
 if p_expected_applied is null or p_expected_refund is null or p_expected_applied<=0 or p_expected_refund<=0 then
  raise exception 'A positive charge total and refund remainder are required.';
 end if;
 select * into r from public.rentals where id=p_rental_id for update;
 if not found then raise exception 'Rental not found.'; end if;
 -- Retrying the same committed application never deducts twice, even after refund.
 select count(*),sum(amount) into n,total from public.rental_deposit_charge_applications
 where rental_id=r.id and charge_id=any(p_charge_ids);
 if n>0 then
  if n<>cardinality(p_charge_ids) or total<>p_expected_applied or
    (select count(*) from public.rental_deposit_charge_applications where rental_id=r.id)<>n then
   raise exception 'A different deposit settlement already exists; refresh the booking.';
  end if;
  select * into a from public.rental_deposit_allocations where id=(select allocation_id from public.rental_deposit_charge_applications where rental_id=r.id limit 1);
  if a.amount_held-a.amount_applied<>p_expected_refund then raise exception 'Settlement amounts changed; refresh the booking.'; end if;
  return jsonb_build_object('applied',total,'refund',p_expected_refund,'duplicate',true);
 end if;
 if r.status<>'completed' or r.inspection_completed_at is null or r.deposit_status<>'held' or
   r.deposit_transferred_to_rental_id is not null or r.deposit_source_rental_id is not null then
  raise exception 'Complete the return and inspection; only an untransferred held deposit can pay charges.';
 end if;
 if public.rentmect_rental_invoice_total(r.id)>public.rentmect_rental_net_paid_amount(r.id)+0.005 then
  raise exception 'Settle the rental invoice before applying its deposit.';
 end if;
 perform 1 from public.rental_deposit_allocations where holder_rental_id=r.id order by id for update;
 if (select count(*) from public.rental_deposit_allocations where holder_rental_id=r.id)<>1 then
  raise exception 'This settlement requires one Stripe deposit allocation.';
 end if;
 select * into a from public.rental_deposit_allocations where holder_rental_id=r.id;
 if a.payment_provider<>'stripe' or a.stripe_payment_intent_id is null or a.source_rental_id<>r.id or
  a.status<>'held' or a.amount_applied<>0 or a.amount_released<>0 or a.refund_id is not null or
  a.refund_reserved_amount is not null then raise exception 'Deposit refund or settlement already started; refresh the booking.'; end if;
 perform 1 from public.rental_charge_items where rental_id=r.id order by id for update;
 select count(*),coalesce(sum(total_amount),0) into n,total from public.rental_charge_items
 where rental_id=r.id and id=any(p_charge_ids) and not included_in_initial_payment
  and charge_type not in ('rental_amendment','rental_installment') and status='pending'
  and stripe_checkout_session_id is null and stripe_payment_intent_id is null and admin_charge_attempted_at is null;
 if n<>cardinality(p_charge_ids) then raise exception 'A selected charge changed or has a payment attempt; reconcile it before applying the deposit.'; end if;
 if total<>p_expected_applied or a.amount_held-total<>p_expected_refund or total>=a.amount_held then
  raise exception 'Deposit or charge amounts changed; refresh and review the settlement.';
 end if;
 for c in select * from public.rental_charge_items where id=any(p_charge_ids) and rental_id=r.id loop
  insert into public.rental_deposit_charge_applications(rental_id,allocation_id,charge_id,amount,reason,actor_id)
   values(r.id,a.id,c.id,c.total_amount,trim(p_reason),p_actor_id);
  update public.rental_charge_items set status='paid',payment_provider='deposit',payment_amount_cents=0,
   paid_at=now(),updated_at=now() where id=c.id;
 end loop;
 -- Check ALL existing inspection, report, toll, continuation and payment blockers.
 blockers:=public.rentmect_deposit_chain_release_blockers(r.id);
 if jsonb_array_length(coalesce(blockers,'[]'))>0 or jsonb_array_length(public.rentmect_deposit_blockers(r.id))>0 then
  raise exception 'Other unresolved charges or deposit blockers remain; resolve them first.';
 end if;
 update public.rental_deposit_allocations set amount_applied=total,updated_at=now() where id=a.id;
 perform public.refresh_rental_deposit_summary(r.id);
 insert into public.rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
 values(r.id,r.user_id,p_actor_id,'deposit_applied_to_charges',jsonb_build_object(
  'allocation_id',a.id,'charge_ids',p_charge_ids,'deposit_captured',a.amount_held,
  'applied_to_charges',total,'refund_remaining',p_expected_refund,'reason',trim(p_reason),'refund_submitted',false));
 return jsonb_build_object('applied',total,'refund',p_expected_refund,'duplicate',false);
end $$;
revoke all on function public.service_apply_deposit_to_charges(uuid,uuid[],numeric,numeric,uuid,text) from public,anon,authenticated;
grant execute on function public.service_apply_deposit_to_charges(uuid,uuid[],numeric,numeric,uuid,text) to service_role;

-- Freeze the refund remainder before contacting Stripe. A competing deduction
-- either commits first or sees the reservation and fails, never changing a live refund.
create function public.service_reserve_deposit_refunds(p_rental_id uuid)
returns setof public.rental_deposit_allocations language plpgsql security definer set search_path=public as $$
declare r public.rentals%rowtype; blockers jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 select * into r from public.rentals where id=p_rental_id for update;
 if not found or (r.status<>'completed' and not(r.status='cancelled' and r.cancelled_before_pickup_at is not null)) then
  raise exception 'Complete the rental return before refunding the deposit.';
 end if;
 blockers:=public.rentmect_deposit_chain_release_blockers(r.id);
 if exists(select 1 from jsonb_array_elements(coalesce(blockers,'[]')) b where not(
  r.status='cancelled' and r.cancelled_before_pickup_at is not null and b->>'rental_id'=r.id::text and
  b->>'type' in ('rental_not_completed','inspection_incomplete'))) then
  raise exception 'Unresolved deposit blockers remain.';
 end if;
 perform 1 from public.rental_deposit_allocations where holder_rental_id=r.id order by id for update;
 update public.rental_deposit_allocations set refund_reserved_amount=amount_held-amount_applied,
  status='release_pending',updated_at=now()
 where holder_rental_id=r.id and payment_provider='stripe' and stripe_payment_intent_id is not null
  and status in ('held','refund_due_inspection','failed','release_pending') and amount_released=0
  and amount_held>amount_applied and refund_reserved_amount is null;
 perform public.refresh_rental_deposit_summary(r.id);
 return query select * from public.rental_deposit_allocations where holder_rental_id=r.id
  and payment_provider='stripe' and status in ('held','refund_due_inspection','failed','release_pending')
  and amount_held>amount_released+amount_applied and refund_reserved_amount is not null;
end $$;
revoke all on function public.service_reserve_deposit_refunds(uuid) from public,anon,authenticated;
grant execute on function public.service_reserve_deposit_refunds(uuid) to service_role;
create or replace function public.refresh_rental_deposit_summary(p_rental_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  r public.rentals%rowtype;
  v_held numeric; v_released numeric; v_pending boolean; v_failed boolean;
  v_completed timestamptz; v_refund text; v_status text;
begin
  select * into r from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if not exists(select 1 from public.rental_deposit_allocations where holder_rental_id=r.id) then return null; end if;
  select coalesce(sum(greatest(0,amount_held-amount_released-amount_applied)),0),coalesce(sum(amount_released),0),
    bool_or(status='release_pending'),bool_or(status='failed'),max(refund_completed_at)
    into v_held,v_released,v_pending,v_failed from public.rental_deposit_allocations where holder_rental_id=r.id;
  select refund_id into v_refund from public.rental_deposit_allocations where holder_rental_id=r.id and refund_id is not null
    order by refund_completed_at desc nulls last,refund_requested_at desc nulls last,id limit 1;
  v_status:=case when v_held<=0.005 then 'released' when v_pending then 'release_pending'
    when coalesce(r.deposit_decrease_refund_due,0)>0 then 'adjustment_refund_due' else 'held' end;
  update public.rentals set deposit_status=v_status,deposit_held_amount=v_held,deposit_released_amount=v_released,
    deposit_refund_id=v_refund,deposit_release_due_at=null,
    deposit_released_at=case when v_held<=0.005 then v_completed else null end,
    deposit_decrease_refund_due=case when v_held<=0.005 then 0 else deposit_decrease_refund_due end,
    deposit_release_error=case when v_failed then 'One or more deposit refund allocations failed.' else null end
    where id=r.id;
  return jsonb_build_object('status',v_status,'unreleased',v_held,'released',v_released);
end;
$$;
revoke all on function public.refresh_rental_deposit_summary(uuid) from public,anon,authenticated;
grant execute on function public.refresh_rental_deposit_summary(uuid) to service_role;

create or replace function public.apply_stripe_deposit_refund(
  p_rental_id uuid,p_allocation_id uuid,p_refund_id text,p_payment_intent_id text,
  p_status text,p_amount numeric,p_failure_reason text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.rental_deposit_allocations%rowtype;
begin
  perform 1 from public.rentals where id=p_rental_id for update;
  select * into a from public.rental_deposit_allocations where id=p_allocation_id and holder_rental_id=p_rental_id for update;
  if not found then raise exception 'Deposit allocation not found.'; end if;
  if a.payment_provider<>'stripe' or p_payment_intent_id is null
    or a.stripe_payment_intent_id is distinct from p_payment_intent_id then
    raise exception 'Stripe refund does not match the deposit payment source.';
  end if;
  if nullif(trim(p_refund_id),'') is null or p_amount is null or p_amount<=0 or p_amount<>a.amount_held-a.amount_applied then
    raise exception 'Invalid deposit refund reference or amount.';
  end if;
  if a.refund_id is not null and a.refund_id<>p_refund_id then
    raise exception 'This allocation already has a different refund reference; reconcile it before changing refunds.';
  end if;
  if a.refund_reserved_amount is not null and p_amount<>a.refund_reserved_amount then
    raise exception 'Refund amount differs from the reserved deposit remainder.';
  end if;
  update public.rental_deposit_allocations set refund_id=p_refund_id,
    status=case when p_status='succeeded' then 'released' when p_status in ('failed','canceled') then 'failed' else 'release_pending' end,
    amount_released=case when p_status='succeeded' then p_amount else 0 end,
    last_error=case when p_status in ('failed','canceled') then coalesce(p_failure_reason,'Stripe refund '||p_status) else null end,
    updated_at=now() where id=a.id;
  return public.refresh_rental_deposit_summary(p_rental_id);
end;
$$;
revoke all on function public.apply_stripe_deposit_refund(uuid,uuid,text,text,text,numeric,text) from public,anon,authenticated;
grant execute on function public.apply_stripe_deposit_refund(uuid,uuid,text,text,text,numeric,text) to service_role;

notify pgrst, 'reload schema';
