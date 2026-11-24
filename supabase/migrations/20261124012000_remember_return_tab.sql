begin;
alter table public.rental_return_reversals add column origin_tab text check (origin_tab in
  ('needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','deposit_review','archive'));

-- Keep each inspection's navigation context with its own recovery snapshot.
do $migration$
declare
  definition text;
  marker text := ' return r;';
  capture text := $body$
 if p_return_context->>'origin_tab' is not null then
   update public.rental_return_reversals set origin_tab=p_return_context->>'origin_tab'
   where rental_id=r.id and created_at=r.inspection_completed_at and reversed_at is null;
   if not found then raise exception 'Return recovery snapshot is missing.'; end if;
 end if;
$body$;
  outcome text;
begin
  definition := pg_get_functiondef('public.admin_inspect_and_complete_rental_return(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean,jsonb)'::regprocedure);
  if strpos(definition,marker)=0 then raise exception 'Inspection definition changed'; end if;
  execute replace(definition,marker,capture||marker);
  definition := pg_get_functiondef('public.undo_rental_return(uuid,text,timestamptz)'::regprocedure);
  foreach outcome in array array['reversed','already_reversed'] loop
    marker := format('jsonb_build_object(''status'',%L)',outcome);
    if strpos(definition,marker)=0 then raise exception 'Recovery definition changed'; end if;
    definition := replace(definition,marker,format('jsonb_build_object(''status'',%L,''origin_tab'',s.origin_tab)',outcome));
  end loop;
  execute definition;
end $migration$;
commit;
