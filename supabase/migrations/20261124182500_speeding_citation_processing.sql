begin;
-- Permit the preceding portal release to finish signing during deployment.
do $$
declare
  d text := pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
  old_list text := '(''rentmect-master-v2026-11-23-speed-incidents'')';
  versions text := '(''rentmect-master-v2026-11-23-speed-incidents'',''rentmect-master-v2026-11-24-citation-processing'')';
  marker text := 'or position($clause$UNRETURNED KEYS';
begin
  if strpos(d,old_list)=0 or strpos(d,marker)=0 then raise exception 'Unexpected signing guard'; end if;
  d := replace(d,old_list,versions);
  d := replace(d,'new.agreement_version = ''rentmect-master-v2026-11-23-speed-incidents''','new.agreement_version in '||versions);
  execute replace(d,marker,$check$or (new.agreement_version = 'rentmect-master-v2026-11-24-citation-processing' and
    strpos(coalesce(new.agreement_snapshot,''),'Rent Me CT charges a $25 processing fee once per official speeding citation that states a speed of 90 mph or more and that Rent Me CT processes for this rental.') = 0)
    $check$||marker);
  d := pg_get_functiondef('public.guard_new_agreement_late_charge()'::regprocedure);
  if strpos(d,'r.agreement_version=''rentmect-master-v2026-11-23-speed-incidents''')=0 then raise exception 'Unexpected grace period guard'; end if;
  execute replace(d,'r.agreement_version=''rentmect-master-v2026-11-23-speed-incidents''','r.agreement_version in '||versions);
end $$;

create function public.check_speeding_citation_fee() returns trigger
language plpgsql set search_path=public as $$
begin
  if new.amount <> 25 or nullif(trim(new.description),'') is null then
    raise exception 'Enter the official citation number and the $25 processing fee.';
  end if;
  if not exists (select 1 from public.rentals r where r.id=new.rental_id and r.agreement_signed and
      strpos(coalesce(r.agreement_snapshot,''),'Rent Me CT charges a $25 processing fee once per official speeding citation')>0) then
    raise exception 'This rental has no signed agreement authorizing the speeding citation processing fee.';
  end if;
  return new;
end $$;
create trigger check_speeding_citation_fee before insert or update of charge_type,amount,description,rental_id on public.rental_charge_items
for each row when (new.charge_type='speeding_citation_processing') execute function public.check_speeding_citation_fee();

create unique index rental_speeding_citation_fee_once on public.rental_charge_items(rental_id,lower(trim(description)))
where charge_type='speeding_citation_processing';

update public.service_fees set active=false where service_type='speeding_violation_fee'
and name='Over 90 MPH 3 Xs Violation Fee' and amount=25;
commit;
