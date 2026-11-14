-- Rolling agreement release: retain physical-return and no-automatic-charge rules.
begin;
do $$ declare d text; begin
 d:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 if position('new.agreement_version is distinct from ''rentmect-master-v2026-11-13-admin-return-r1''' in d)=0 then
  raise exception 'Unexpected agreement version baseline';
 end if;
 d:=replace(d,'new.agreement_version is distinct from ''rentmect-master-v2026-11-13-admin-return-r1''',
  '(new.agreement_version is null or new.agreement_version not in (''rentmect-master-v2026-11-13-admin-return-r1'',''rentmect-master-v2026-11-13-admin-return-r2''))');
 execute d;
end $$;
commit;
