begin;
do $migration$
declare
  definition text := pg_get_functiondef('public.rentmect_freeze_extension_quote()'::regprocedure);
  pricing_query text := 'select rate from public.ct_extension_pricing(r,new.replacement_vehicle_id,new.request_kind,new.requested_return_date,new.requested_return_time)';
begin
  if strpos(definition,pricing_query)=0 then raise exception 'Extension quote definition changed'; end if;
  execute replace(definition,pricing_query,replace(pricing_query,'select rate','select pricing.rate')||' as pricing');
end $migration$;
commit;
