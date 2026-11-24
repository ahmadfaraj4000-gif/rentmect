begin;
-- Deny new charges from both former menu options, including cached clients.
create function public.reject_suspended_speeding_fee() returns trigger language plpgsql as $$
begin
 raise exception 'This fee is suspended pending review.';
end $$;
create trigger block_suspended_speeding_fee before insert or update of charge_type on public.rental_charge_items
for each row when (new.charge_type in ('excessive_speeding','speeding_citation_processing','speeding_violation_fee'))
execute function public.reject_suspended_speeding_fee();

do $$ declare d text:=pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 previous text:='new.agreement_version <> ''rentmect-master-v2026-11-24-excessive-speeding''';
begin
 if strpos(d,previous)=0 then raise exception 'Unexpected signature guard'; end if;
 execute replace(d,previous,'new.agreement_version not in (''rentmect-master-v2026-11-24-excessive-speeding'',''rentmect-master-v2026-11-23-speed-incidents'')');
end $$;
commit;
