begin;
set local lock_timeout='5s';
alter table public.rentals add column deposit_review_approved_at timestamptz,
 add column deposit_review_note text, add column deposit_review_follow_up_at timestamptz;

create function public.rentmect_needs_deposit_review(r public.rentals) returns boolean
language sql stable set search_path=public as $$
 select r.status='completed' and r.ending_mileage is not null
 and (coalesce(r.deposit_held_amount,0)>0 or r.deposit_status in ('release_pending','adjustment_refund_due'))
 and r.deposit_status not in ('waived','transferred','released')
$$;
create function public.guard_deposit_review_schedule() returns trigger language plpgsql set search_path=public as $$
begin
 if new.status='completed' and new.deposit_review_approved_at is null then new.deposit_release_due_at:=null; end if;
 return new;
end $$;
create trigger zzz_require_deposit_review before insert or update on public.rentals
 for each row execute function public.guard_deposit_review_schedule();
-- Existing unresolved returns need review too; no cash or allocation is changed.
update public.rentals set deposit_release_due_at=null where status='completed' and deposit_review_approved_at is null and deposit_release_due_at is not null;

create function public.admin_hold_deposit_review(p_rental_id uuid,p_note text,p_follow_up_at timestamptz)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() or not coalesce(rentmect_has_permission('deposit.resolve'),false) then raise exception 'Deposit resolution permission required.'; end if;
 if length(trim(coalesce(p_note,'')))<5 or p_follow_up_at is null or p_follow_up_at<=now() then raise exception 'Enter a hold reason and a future follow-up date.'; end if;
 perform 1 from rentals r where id=p_rental_id and rentmect_needs_deposit_review(r) for update;
 if not found then raise exception 'This rental is not awaiting deposit review.'; end if;
 update rentals set deposit_review_note=trim(p_note),deposit_review_follow_up_at=p_follow_up_at,
  deposit_review_approved_at=null,deposit_release_due_at=null where id=p_rental_id;
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload)
 values(p_rental_id,auth.uid(),'deposit_review_held',jsonb_build_object('reason',trim(p_note),'follow_up_at',p_follow_up_at));
end $$;
revoke all on function public.admin_hold_deposit_review(uuid,text,timestamptz) from public,anon;
grant execute on function public.admin_hold_deposit_review(uuid,text,timestamptz) to authenticated;

-- One charge may use several original deposit sources. Applications remain immutable.
alter table public.rental_deposit_charge_applications drop constraint rental_deposit_charge_applications_charge_id_key;
create unique index deposit_source_charge_once on public.rental_deposit_charge_applications(allocation_id,charge_id);
create table public.deposit_review_settlements(
 id uuid primary key, rental_id uuid not null references public.rentals(id), actor_id uuid not null references auth.users(id),
 request jsonb not null,result jsonb not null,created_at timestamptz not null default now());
alter table public.deposit_review_settlements enable row level security;
revoke all on public.deposit_review_settlements from public,anon,authenticated;
grant all on public.deposit_review_settlements to service_role;

create or replace function public.check_deposit_application_total() returns trigger
language plpgsql security definer set search_path=public as $$
declare aid uuid; a rental_deposit_allocations%rowtype;
begin
 if tg_table_name='rental_deposit_allocations' then aid:=new.id; else aid:=new.allocation_id; end if;
 select * into a from rental_deposit_allocations where id=aid;
 if a.amount_applied<>(select coalesce(sum(amount),0) from rental_deposit_charge_applications where allocation_id=aid) then raise exception 'Applied deposit total must match charge applications.'; end if;
 if exists(select 1 from rental_deposit_charge_applications d join rental_charge_items c on c.id=d.charge_id
 where d.allocation_id=aid and (d.rental_id<>a.holder_rental_id or c.rental_id<>d.rental_id or
 (case when c.allocation_managed then c.allocated_deposit_cents<>round((select sum(amount) from rental_deposit_charge_applications where charge_id=c.id)*100)
   or c.allocated_payment_cents+c.allocated_deposit_cents+c.allocated_waiver_cents>round(c.total_amount*100)
  else c.status<>'paid' or c.payment_provider is distinct from 'deposit' or c.total_amount<>(select sum(amount) from rental_deposit_charge_applications where charge_id=c.id) end))) then
 raise exception 'Deposit applications must match charges on the same rental.'; end if;
 return null;
end $$;

do $$ declare d text; begin
 select pg_get_functiondef('public.protect_deposit_settlement()'::regprocedure) into d;
 d:=replace(d,$m$elsif TG_TABLE_NAME='rental_charge_items' then$m$,$p$elsif TG_TABLE_NAME='rental_charge_items' then
  if auth.role()='service_role' and current_setting('rentmect.deposit_review_write',true)='on' then return new; end if;$p$);
 execute d;
 select pg_get_functiondef('public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) into d;
 if position('''all'',''archive''' in d)=0 then raise exception 'Review rental filter contract'; end if;
 d:=replace(d,'''all'',''archive''','''all'',''archive'',''deposit_review''');
 d:=replace(d,'r.pickup_date,r.pickup_time,', 'public.rentmect_needs_deposit_review(r) as deposit_review,r.inspection_completed_at as return_completed_at,r.ending_mileage,r.deposit_review_note,r.deposit_review_follow_up_at,r.pickup_date,r.pickup_time,');
 d:=replace(d,'''archive'',terminal,', '''archive'',terminal and not deposit_review,''deposit_review'',deposit_review,');
 -- Keep all existing list joins, permissions and count logic intact.
 d:=replace(d,'order by created_at desc,id desc', 'order by case when p_filter=''deposit_review'' then return_completed_at end asc nulls last,created_at desc,id desc');
 execute d;
end $$;

create function public.service_apply_deposit_review(p_id uuid,p_rental_id uuid,p_actor_id uuid,p_request jsonb,p_charges jsonb,p_allocations jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; saved deposit_review_settlements%rowtype; a rental_deposit_allocations%rowtype; c rental_charge_items%rowtype;
 ids uuid[]; selected_total numeric:=0; held numeric:=0; budget numeric; needed numeric; used numeric; applied numeric:=0; result jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'Service role required.'; end if;
 perform require_external_payment_actor(p_actor_id,'deposit.resolve');
 select * into strict r from rentals where id=p_rental_id for update;
 select * into saved from deposit_review_settlements where id=p_id;
 if found then
  if saved.rental_id<>p_rental_id or saved.request<>p_request then raise exception 'Deposit review key already used.'; end if;
  return saved.result;
 end if;
 if r.status<>'completed' or r.ending_mileage is null or r.inspection_completed_at is null then raise exception 'Complete the return inspection and record ending mileage before reviewing the deposit.'; end if;
 if length(trim(coalesce(p_request->>'reason','')))<5 then raise exception 'Enter a review reason.'; end if;
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
 perform refresh_rental_deposit_summary(r.id);
 update rentals set deposit_review_approved_at=now(),deposit_review_note=p_request->>'reason',deposit_review_follow_up_at=null where id=r.id;
 result:=jsonb_build_object('applied',applied,'remaining',held-applied);
 insert into deposit_review_settlements values(p_id,r.id,p_actor_id,p_request,result,now());
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(r.id,p_actor_id,'deposit_review_approved',result||jsonb_build_object('request',p_request));
 perform set_config('rentmect.external_payment_write','',true);perform set_config('rentmect.deposit_review_write','',true);
 return result;
end $$;
revoke all on function public.service_apply_deposit_review(uuid,uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.service_apply_deposit_review(uuid,uuid,uuid,jsonb,jsonb,jsonb) to service_role;
notify pgrst,'reload schema';
commit;
