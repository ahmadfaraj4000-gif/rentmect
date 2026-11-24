-- Apply once both signing portals serve the new agreement.
begin;
do $$
declare
  d text := pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
  previous text := 'new.agreement_version not in
    (''rentmect-master-v2026-11-23-speed-incidents'',''rentmect-master-v2026-11-24-citation-processing'')';
begin
  if strpos(d,previous)=0 then raise exception 'Unexpected signing guard'; end if;
  execute replace(d,previous,'new.agreement_version <> ''rentmect-master-v2026-11-24-citation-processing''');
end $$;
commit;
