-- Patch both paginated projections in place, preserving live authorization,
-- card summaries, physical-return policy and all unrelated definitions.
begin;
set local lock_timeout='2s';
set local statement_timeout='10s';
do $patch$
declare sig text; d text; old text; new text; pair text[];
begin
 foreach sig in array array['public.admin_rental_list(text,text,integer,integer,uuid)', 'public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[])'] loop
  d:=pg_get_functiondef(sig::regprocedure);
  foreach pair slice 1 in array array[
   array['r.status in (''active'',''overdue'',''return_initiated'') as cars_out','r.status in (''active'',''rented'',''overdue'',''return_initiated'') as cars_out'],
   array['coalesce(v.status in (''maintenance'',''unavailable'',''inactive''),false) as maintenance','(coalesce(v.maintenance_lock_active,false) or coalesce(v.status in (''maintenance'',''unavailable'',''inactive'',''retired''),false)) as maintenance'],
   array['''extensions'',open_extension,''maintenance'',maintenance','''extensions'',not terminal and open_extension,''maintenance'',not terminal and maintenance'],
   array['''ready_pickup'',release_ready and status not in (''active'',''overdue'',''return_initiated'',''completed'',''cancelled'')','''ready_pickup'',release_ready and not terminal and not vehicle_out and not maintenance'],
   array['or (not vehicle_out and not release_ready)','or (not vehicle_out and (not release_ready or maintenance))'],
   array['''approved'',''active'',''overdue'',''return_initiated''))','''approved'',''active'',''rented'',''overdue'',''return_initiated''))']
  ] loop
   old:=pair[1]; new:=pair[2];
   if position(old in d)=0 then raise exception 'Unexpected filter baseline for %: %',sig,old; end if;
   d:=replace(d,old,new);
  end loop;
  execute d;
 end loop;
end $patch$;
notify pgrst,'reload schema';
commit;
