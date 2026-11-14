-- In a rollback transaction, capture each original list response in pg_temp.card_baseline
-- (filter text, response jsonb) before applying the workflow summary migration.
do $$ declare b record; actual jsonb; normalized jsonb; delta jsonb; ids uuid[]; card jsonb; begin
 for b in select * from pg_temp.card_baseline loop
  actual:=public.admin_rental_list(b.filter,'',0,25,null);
  select coalesce(jsonb_agg(x-'card'),'[]'::jsonb) into normalized from jsonb_array_elements(actual->'rows') x;
  if jsonb_set(actual,'{rows}',normalized) is distinct from b.response then raise exception 'Original summary changed: %',b.filter; end if;
  select coalesce(array_agg((x->>'id')::uuid),'{}'::uuid[]) into ids from jsonb_array_elements(actual->'rows') x;
  delta:=public.admin_rental_summary_changes(b.filter,'',0,25,null,ids,ids);
  if delta->'rows' is distinct from actual->'rows' then raise exception 'Workflow delta mismatch: %',b.filter; end if;
  for card in select x->'card' from jsonb_array_elements(actual->'rows') x loop
   if not (card ?& array['rental','documents','completion_scopes','emergency','extensions']) then raise exception 'Missing workflow projection'; end if;
   if exists(select 1 from jsonb_array_elements(card->'documents') d where d ?| array['file_path','storage_path','file_url','signed_url']) then raise exception 'Document files leaked into summary'; end if;
  end loop;
 end loop;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.admin_rental_card_summary(null); raise exception 'Anonymous workflow access allowed'; exception when insufficient_privilege then null; end;
end $$;
