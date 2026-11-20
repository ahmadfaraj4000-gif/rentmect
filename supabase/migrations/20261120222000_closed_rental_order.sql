-- Keep pagination, aggregate order and realtime visible IDs in the same order.
do $migration$
declare
  signature regprocedure;
  definition text;
  old_order text := 'case when p_filter=''deposit_review'' then return_completed_at end asc nulls last,created_at desc,id desc';
  new_order text := 'case when oldest_first then closed_at end asc nulls last,
    case when not oldest_first and p_filter in (''archive'',''deposit_review'') then closed_at end desc nulls last,created_at desc,id desc';
begin
  foreach signature in array array[
    'public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure,
    'public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[])'::regprocedure
  ] loop
    definition := pg_get_functiondef(signature);
    if strpos(definition, old_order) = 0 or strpos(definition,'declare result jsonb;') = 0
       or strpos(definition,'r.inspection_completed_at as return_completed_at') = 0 then
      raise exception 'Unexpected rental list definition for %', signature;
    end if;
    definition := replace(definition,'declare result jsonb;', $body$declare result jsonb;
      oldest_first boolean := p_filter in ('deposit_review_oldest','archive_oldest');$body$);
    definition := replace(definition,'if p_filter is null', $body$if oldest_first then p_filter := split_part(p_filter,'_oldest',1); end if;
      if p_filter is null$body$);
    definition := replace(definition,'r.inspection_completed_at as return_completed_at',
      'case when r.status=''cancelled'' then coalesce(r.cancelled_at,r.cancelled_before_pickup_at) else r.inspection_completed_at end as closed_at, r.inspection_completed_at as return_completed_at');
    execute replace(definition,old_order,new_order);
  end loop;
end
$migration$;
