begin;
alter table rentals add column manual_deposit_hold boolean not null default false, add column deposit_held_reviewed_at timestamptz;
create function admin_retain_rental_deposit(p_rental_id uuid,p_note text,p_report_id uuid default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; held numeric;
begin
 if not is_admin() or not coalesce(rentmect_has_permission('deposit.resolve'),false) then raise exception 'Deposit resolution permission required.'; end if;
 select * into strict r from rentals where id=p_rental_id for update;
 if r.status<>'completed' or r.ending_mileage is null then raise exception 'Complete the rental return and inspection before retaining its deposit.'; end if;
 if length(trim(coalesce(p_note,'')))=0 then raise exception 'Enter a reason for keeping the deposit.'; end if;
 select coalesce(sum(greatest(0,amount_held-amount_applied-amount_released)),0) into held from rental_deposit_allocations where holder_rental_id=r.id;
 if held<=0 then raise exception 'No deposit remains to hold.'; end if;
 if exists(select 1 from rental_deposit_allocations where holder_rental_id=r.id and (refund_reserved_amount is not null or status='release_pending')) then raise exception 'A refund has started. Reconcile it before holding the deposit.'; end if;
 if p_report_id is not null then
  update vehicle_reports set status='open',resolved_at=null,deposit_hold_active=true,deposit_held_amount=held,admin_notes=trim(p_note) where id=p_report_id and rental_id=r.id;
  if not found then raise exception 'Case does not belong to this rental.'; end if;
 end if;
 update rentals set damage_deposit_hold=true,manual_deposit_hold=manual_deposit_hold or p_report_id is null,
 deposit_held_reviewed_at=now(),deposit_review_approved_at=null,deposit_release_due_at=null,deposit_review_follow_up_at=null,deposit_review_note=trim(p_note) where id=r.id;
 perform sync_deposit_action_task(r.id);
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(r.id,auth.uid(),'deposit_retained',jsonb_build_object('note',p_note,'report_id',p_report_id,'amount',held));
 return jsonb_build_object('rental_id',r.id,'held',held);
end $$;
revoke all on function admin_retain_rental_deposit(uuid,text,uuid) from public,anon;
grant execute on function admin_retain_rental_deposit(uuid,text,uuid) to authenticated;
do $$ declare d text; begin
 select pg_get_functiondef('admin_damage_case_action(uuid,text,text)'::regprocedure) into d;
 d:=replace(d,'update rentals set damage_deposit_hold=true,deposit_review_approved_at=null,deposit_release_due_at=null,deposit_review_note=trim(p_note) where id=rid;','perform admin_retain_rental_deposit(rid,p_note,report.id);');
 d:=replace(d,'set damage_deposit_hold=active_hold,','set damage_deposit_hold=active_hold or manual_deposit_hold,');
 execute d;
 select pg_get_functiondef('admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) into d;
 execute replace(d,'r.damage_deposit_hold,','r.damage_deposit_hold,r.manual_deposit_hold,r.deposit_held_reviewed_at,');
 select pg_get_functiondef('rentmect_deposit_chain_release_blockers(uuid)'::regprocedure) into d;
 if position('blockers as (' in d)=0 then raise exception 'Deposit blockers contract changed'; end if;
 execute replace(d,'blockers as (', 'blockers as (select jsonb_build_object(''type'',''deposit_retained'',''rental_id'',r.id,''detail'',''Deposit kept after review. Resume deposit review before refunding.'') as blocker from rentals r join chain on chain.id=r.id where r.damage_deposit_hold union all ');
end $$;
create function admin_resume_deposit_review(p_rental_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not is_admin() or not coalesce(rentmect_has_permission('deposit.resolve'),false) then raise exception 'Deposit resolution permission required.'; end if;
 perform 1 from rentals where id=p_rental_id for update;
 update rentals set damage_deposit_hold=false,manual_deposit_hold=false,deposit_held_reviewed_at=null,deposit_review_approved_at=null where id=p_rental_id;
 update vehicle_reports set deposit_hold_active=false,deposit_held_amount=0 where rental_id=p_rental_id and deposit_hold_active;
 perform sync_deposit_action_task(p_rental_id);
 insert into rental_audit_events(rental_id,actor_id,event_type,event_payload) values(p_rental_id,auth.uid(),'deposit_review_resumed','{}');
end $$;
revoke all on function admin_resume_deposit_review(uuid) from public,anon;
grant execute on function admin_resume_deposit_review(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
