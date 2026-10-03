-- Read-only assertions. Run inside a transaction after installing the migration,
-- with request.jwt.claim.sub set to an authorized admin and role authenticated.
do $test$
declare a jsonb; b jsonb; d jsonb; filter text; uid text:=current_setting('request.jwt.claim.sub');
  rental_id uuid; user_id uuid; started timestamptz:=clock_timestamp();
begin
  foreach filter in array array['needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive'] loop
    a:=public.admin_rental_list(filter,'',0,25);
    if (a->>'total')::integer<>(a->'counts'->>filter)::integer then raise exception 'Count mismatch: %',filter; end if;
    if jsonb_array_length(a->'rows')>25 then raise exception 'Page limit ignored'; end if;
    if exists(select 1 from jsonb_array_elements(a->'rows') item where item ? 'agreement_snapshot' or item ? 'profiles' or item ? 'search_text') then
      raise exception 'List includes full detail or private search metadata'; end if;
    if filter='archive' and exists(select 1 from jsonb_array_elements(a->'rows') item where item->>'status' not in ('completed','cancelled')) then
      raise exception 'Nonterminal rental in archive'; end if;
  end loop;
  a:=public.admin_rental_list('archive','',0,25);
  b:=public.admin_rental_list('archive','',25,25);
  if exists(select 1 from jsonb_array_elements(a->'rows') x join jsonb_array_elements(b->'rows') y on x->>'id'=y->>'id') then
    raise exception 'Archive pages overlap'; end if;
  if jsonb_array_length(public.admin_rental_list('archive','no matching customer 8675309',0,25)->'rows')<>0 then
    raise exception 'Search is not applied by server'; end if;
  for rental_id in select id from public.rentals order by created_at desc limit 3 loop
    d:=public.admin_rental_detail(rental_id);
    user_id:=(d->'rental'->>'user_id')::uuid;
    if (d->'rental'->>'id')::uuid<>rental_id then raise exception 'Wrong detail rental'; end if;
    foreach filter in array array['reports','extensions','exceptions','steps','payments','refunds','charges','externalActions'] loop
      if exists(select 1 from jsonb_array_elements(d->filter) item where (item->>'rental_id')::uuid is distinct from rental_id) then
        raise exception 'Unrelated records in %',filter; end if;
    end loop;
    if exists(select 1 from jsonb_array_elements(d->'documents') item where (item->>'rental_id')::uuid is distinct from rental_id
      and not ((item->>'user_id')::uuid=user_id and item->>'document_type'='license')) then raise exception 'Unrelated document'; end if;
  end loop;
  begin
    perform public.admin_rental_list('archive','',0,500);
    raise exception 'FAILED unbounded page';
  exception when others then if sqlerrm<>'Invalid rental page.' then raise; end if; end;
  begin
    perform public.admin_rental_list('invented_filter');
    raise exception 'FAILED invalid filter';
  exception when others then if sqlerrm<>'Unknown rental filter.' then raise; end if; end;
  if exists(select 1 from pg_proc where pronamespace='public'::regnamespace
    and proname in ('admin_rental_list','admin_rental_detail') and prosecdef) then raise exception 'Reads bypass RLS'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.admin_rental_list();
    raise exception 'FAILED anonymous permission guard';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',user_id::text,true);
  begin
    perform public.admin_rental_detail(rental_id);
    raise exception 'FAILED customer permission guard';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',uid,true);
  raise notice 'Rental workspace read assertions passed in % ms',extract(epoch from clock_timestamp()-started)*1000;
end; $test$;
