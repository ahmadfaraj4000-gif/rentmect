begin;
-- Run after both signing portals serve the new agreement. The trigger validates
-- new signatures only. Prior signed copies retain the date and terms accepted.
do $$ declare d text; original text; begin
 d:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 original:=$v$('rentmect-master-v2026-11-13-admin-return-r2','rentmect-master-v2026-11-23-speed-incidents')$v$;
 if position(original in d)=0 then raise exception 'Review the installed signing version before finalizing rollout.'; end if;
 execute replace(d,original,$v$('rentmect-master-v2026-11-23-speed-incidents')$v$);
 d:=pg_get_functiondef('public.undo_rental_return(uuid,text,timestamptz)'::regprocedure);
 original:=$v$and report_type='admin_return_damage')$v$;
 if position(original in d)=0 then raise exception 'Review the installed return reversal definition.'; end if;
 d:=replace(d,original,$v$and report_type='admin_return_damage' and lower(coalesce(status,'open')) not in ('closed','resolved'))$v$);
 d:=replace(d,$v$'security_deposit_refund','deposit_release','rental_return'$v$,$v$'security_deposit_refund','security_deposit_refunded','deposit_release','rental_return'$v$);
 execute d;
end $$;
commit;
