begin;
-- Only the code-verified recovery RPC can write this private row. Mark its
-- transaction before restoring the rental; a failed restoration rolls it back.
alter table public.rental_return_reversals add column reversal_transaction xid8;
create function public.restoring_existing_vehicle_possession(rental uuid, inspected timestamptz, prior_status text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select from public.rental_return_reversals s
    where s.rental_id=rental and s.created_at=inspected and s.reversed_by=auth.uid()
      and s.reversal_transaction=pg_current_xact_id_if_assigned() and s.prior_rental->>'status'=prior_status)
$$;
revoke all on function public.restoring_existing_vehicle_possession(uuid,timestamptz,text) from public,anon,authenticated;

do $migration$
declare d text; signoff text:='update public.rental_return_reversals set reversed_at=clock_timestamp(),reversed_by=auth.uid() where inspection_id=s.inspection_id;';
  marker text:='  old_r:=jsonb_populate_record'; f regprocedure;
begin
  d:=pg_get_functiondef('public.undo_rental_return(uuid,text,timestamptz)'::regprocedure);
  if strpos(d,signoff)=0 or strpos(d,marker)=0 then raise exception 'Return recovery definition changed'; end if;
  d:=replace(d,signoff,'');
  execute replace(d,marker,'  update public.rental_return_reversals set reversed_at=clock_timestamp(),reversed_by=auth.uid(),reversal_transaction=pg_current_xact_id() where inspection_id=s.inspection_id;'||chr(10)||marker);
  foreach f in array array['public.enforce_completed_deposit_before_vehicle_release()'::regprocedure,
                            'public.enforce_identity_before_vehicle_release()'::regprocedure] loop
    d:=pg_get_functiondef(f);
    if strpos(d,'begin'||chr(10)||'  if lower(coalesce(new.status')=0 then raise exception 'Pickup guard definition changed: %',f; end if;
    execute replace(d,'begin'||chr(10)||'  if lower(coalesce(new.status',
      $guard$begin
  if tg_op='UPDATE' and old.status='completed' and new.status='active' and new.inspection_completed_at is null
     and public.restoring_existing_vehicle_possession(old.id,old.inspection_completed_at,new.status) then
    return new;
  end if;
  if lower(coalesce(new.status$guard$);
  end loop;
end $migration$;
commit;
