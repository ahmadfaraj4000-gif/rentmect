-- Edits lock the target schedule before taking vehicle row/FK locks. Swaps must
-- use that same order, or an edit and swap can deadlock on the same target.
do $migration$
declare definition text;
 old_block text := $old$ perform 1 from vehicles where id in(r.vehicle_id,p_vehicle_id) order by id for update;$old$;
 new_block text := $new$ perform pg_advisory_xact_lock(hashtext(p_vehicle_id::text));
 perform 1 from vehicles where id in(r.vehicle_id,p_vehicle_id) order by id for update;$new$;
begin
 select pg_get_functiondef('public.admin_apply_vehicle_swap(uuid,uuid,timestamptz,text,text,numeric,uuid,text,integer,integer)'::regprocedure) into definition;
 if position(new_block in definition)>0 then return; end if;
 if position(old_block in definition)=0 then raise exception 'Review changed swap vehicle locks before migrating.'; end if;
 execute replace(definition,old_block,new_block);
end;
$migration$;
