begin;
alter table public.vehicle_reports add column deposit_hold_active boolean not null default false;
alter table public.rentals add column damage_deposit_hold boolean not null default false;
create function public.admin_damage_case_action(p_report_id uuid,p_action text,p_note text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare report vehicle_reports%rowtype; rent rentals%rowtype; held numeric; active_hold boolean; rid uuid;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('customer.manage'),false) then raise exception 'Case management permission required.'; end if;
 if p_action not in ('hold','resolve') then raise exception 'Invalid case action.'; end if;
 select rental_id into rid from vehicle_reports where id=p_report_id;
 if rid is not null then select * into rent from rentals where id=rid for update; end if;
 select * into strict report from vehicle_reports where id=p_report_id for update;
 if report.rental_id is distinct from rid then raise exception 'Case rental changed. Reload the case.'; end if;
 if p_action='hold' then
  if not coalesce(rentmect_has_permission('deposit.resolve'),false) then raise exception 'Deposit resolution permission required.'; end if;
  if rent.id is null or rent.status<>'completed' or rent.ending_mileage is null then raise exception 'Complete the rental return before holding its deposit in Archive.'; end if;
  if length(trim(coalesce(p_note,'')))<1 then raise exception 'Enter a reason for holding the deposit.'; end if;
  select coalesce(sum(greatest(0,amount_held-amount_applied-amount_released)),0) into held from rental_deposit_allocations where holder_rental_id=rid;
  if held<=0 then raise exception 'No deposit remains to hold.'; end if;
  if exists(select 1 from rental_deposit_allocations where holder_rental_id=rid and (refund_reserved_amount is not null or status in ('release_pending'))) then raise exception 'A deposit refund has started. Reconcile it before placing a hold.'; end if;
  update vehicle_reports set status='open',resolved_at=null,deposit_hold_active=true,deposit_held_amount=held,admin_notes=trim(p_note) where id=report.id;
  update rentals set damage_deposit_hold=true,deposit_review_approved_at=null,deposit_release_due_at=null,deposit_review_note=trim(p_note) where id=rid;
 else
  update vehicle_reports set status='resolved',resolved_at=now(),deposit_hold_active=false,deposit_held_amount=0,
   admin_notes=case when length(trim(coalesce(p_note,'')))>0 then trim(p_note) else admin_notes end where id=report.id;
  if rid is not null then
   select exists(select 1 from vehicle_reports where rental_id=rid and deposit_hold_active) into active_hold;
   update rentals set damage_deposit_hold=active_hold,
    deposit_review_approved_at=case when rent.damage_deposit_hold and not active_hold then null else deposit_review_approved_at end,
    deposit_review_follow_up_at=case when rent.damage_deposit_hold and not active_hold then null else deposit_review_follow_up_at end
    where id=rid;
  end if;
 end if;
 if rid is not null then
  perform sync_deposit_action_task(rid);
  insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(rid,auth.uid(),case when p_action='hold' then 'damage_deposit_held' else 'damage_case_resolved' end,jsonb_build_object('report_id',report.id,'note',p_note));
 end if;
 return jsonb_build_object('report_id',report.id,'rental_id',rid,'action',p_action,'damage_deposit_hold',(select damage_deposit_hold from rentals where id=rid));
end $$;
revoke all on function public.admin_damage_case_action(uuid,text,text) from public,anon;
grant execute on function public.admin_damage_case_action(uuid,text,text) to authenticated;
do $$ declare d text; begin
 select pg_get_functiondef('public.admin_damage_cases_page(text,integer)'::regprocedure) into d;
 execute replace(d,'c.id,c.created_at,c.status,','c.id,c.created_at,c.status,c.deposit_hold_active,');
 select pg_get_functiondef('public.rentmect_needs_deposit_review(public.rentals)'::regprocedure) into d;
 if position('r.status=''completed''' in d)=0 then raise exception 'Deposit review contract changed'; end if;
 execute replace(d,'r.status=''completed''','r.status=''completed'' and not r.damage_deposit_hold');
 select pg_get_functiondef('public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) into d;
 if position('r.deposit_review_note,' in d)=0 then raise exception 'Rental summary contract changed'; end if;
 execute replace(d,'r.deposit_review_note,','r.damage_deposit_hold,r.deposit_review_note,');
 select pg_get_functiondef('public.rentmect_deposit_chain_release_blockers(uuid)'::regprocedure) into d;
 if position('lower(coalesce(report.status, ''open'')) not in (''resolved'', ''closed'', ''completed'')' in d)=0 then raise exception 'Report blocker contract changed'; end if;
 execute replace(d,'lower(coalesce(report.status, ''open'')) not in (''resolved'', ''closed'', ''completed'')','(lower(coalesce(report.status, ''open'')) not in (''resolved'', ''closed'', ''completed'') or report.deposit_hold_active)');
end $$;
notify pgrst,'reload schema';
commit;
