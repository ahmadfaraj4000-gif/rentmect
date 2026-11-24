-- Accept both versions while the two portals roll out. Old signatures remain immutable.
begin;
do $migration$
declare
  prior text := 'new.agreement_version is distinct from ''rentmect-master-v2026-11-13-admin-return-r2''';
  definition text := pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
begin
  if strpos(definition, prior) = 0 then raise exception 'Unexpected signing guard. Compare live agreement version before rollout.'; end if;
  execute replace(definition, prior, $guard$(new.agreement_version is null or new.agreement_version not in
    ('rentmect-master-v2026-11-13-admin-return-r2','rentmect-master-v2026-11-23-speed-incidents')
    or (new.agreement_version = 'rentmect-master-v2026-11-23-speed-incidents'
        and strpos(coalesce(new.agreement_snapshot,''),'The third incident triggers a recovery review regardless of how many warnings were issued or received.') = 0))$guard$);
end $migration$;
update public.service_fees
set description = 'The third distinct over-90-mph or reckless-driving incident during the rental triggers staff review regardless of warnings.'
where service_type = 'speeding_violation_fee'
and description = 'Each time over 90 MPH; after the fourth event disable the vehicle and apply the mandatory reactivation fee.';
commit;
