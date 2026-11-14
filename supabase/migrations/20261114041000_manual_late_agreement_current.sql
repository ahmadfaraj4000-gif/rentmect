-- Apply after both portals serve r2. Previously signed snapshots remain intact.
begin;
do $$ declare d text; begin
 d:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 if position('(new.agreement_version is null or new.agreement_version not in (''rentmect-master-v2026-11-13-admin-return-r1'',''rentmect-master-v2026-11-13-admin-return-r2''))' in d)=0 then
  raise exception 'Unexpected agreement compatibility baseline';
 end if;
 d:=replace(d,'(new.agreement_version is null or new.agreement_version not in (''rentmect-master-v2026-11-13-admin-return-r1'',''rentmect-master-v2026-11-13-admin-return-r2''))',
  'new.agreement_version is distinct from ''rentmect-master-v2026-11-13-admin-return-r2''');
 execute d;
end $$;
commit;
