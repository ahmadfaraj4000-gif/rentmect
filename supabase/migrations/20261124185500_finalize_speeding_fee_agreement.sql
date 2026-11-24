begin;
do $$ declare d text:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 previous text:='new.agreement_version not in (''rentmect-master-v2026-11-24-citation-processing'',''rentmect-master-v2026-11-24-excessive-speeding'')';
begin
 if strpos(d,previous)=0 then raise exception 'Unexpected signature guard'; end if;
 execute replace(d,previous,'new.agreement_version <> ''rentmect-master-v2026-11-24-excessive-speeding''');
end $$;
commit;
