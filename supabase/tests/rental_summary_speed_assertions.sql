-- Run inside a rollback transaction after creating pg_temp.speed_baseline from the fixture and applying the candidate.
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role='admin' limit 1),true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$ declare f text; q text; a jsonb; b jsonb; d jsonb; ids uuid[]; begin
 foreach f in array array['needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive','deposit_review'] loop
  foreach q in array array['','Audi','zz-no-match'] loop
   a:=pg_temp.speed_baseline(f,q,0,25,null);
   b:=public.admin_rental_list(f,q,0,25,null);
   if a is distinct from b then raise exception 'List mismatch: % %',f,q; end if;
   select coalesce(array_agg((x->>'id')::uuid),'{}'::uuid[]) into ids from jsonb_array_elements(b->'rows') x;
   d:=public.admin_rental_summary_changes(f,q,0,25,null,ids,ids);
   if d->'rows' is distinct from b->'rows' or d->'counts' is distinct from b->'counts' or d->'total' is distinct from b->'total' then raise exception 'Delta mismatch: % %',f,q; end if;
   d:=public.admin_rental_summary_changes(f,q,0,25,null,'{}',ids);
   if d->'rows'<>'[]'::jsonb or jsonb_array_length(d->'visible_ids')<>cardinality(ids) then raise exception 'Unchanged rows transmitted: %',f; end if;
  end loop;
 end loop;
 perform set_config('request.jwt.claim.sub','',true);
 begin perform public.admin_rental_summary_changes(); raise exception 'Anonymous access allowed'; exception when insufficient_privilege then null; end;
end $$;
