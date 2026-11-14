-- Apply after both portals serve the new agreement. Existing signatures stay intact.
begin;
do $$ declare d text; begin
 d:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 d:=replace(d, '(new.agreement_version is null or new.agreement_version not in (''rentmect-master-v2026-10-23-unreturned-keys-r1'',''rentmect-master-v2026-11-13-admin-return-r1''))',
  'new.agreement_version is distinct from ''rentmect-master-v2026-11-13-admin-return-r1''');
 execute d;
end $$;
commit;
