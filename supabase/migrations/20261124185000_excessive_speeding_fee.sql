begin;
do $$
declare
 old_version text := '''rentmect-master-v2026-11-24-citation-processing''';
 new_version text := '''rentmect-master-v2026-11-24-excessive-speeding''';
 d text := pg_get_functiondef('public.require_current_rental_agreement()'::regprocedure);
 marker text := 'or position($clause$UNRETURNED KEYS';
begin
 if strpos(d,'new.agreement_version <> '||old_version)=0 or strpos(d,marker)=0 then raise exception 'Unexpected signature guard'; end if;
 d := replace(d,'new.agreement_version <> '||old_version,'new.agreement_version not in ('||old_version||','||new_version||')');
 d := replace(d,'new.agreement_version in (''rentmect-master-v2026-11-23-speed-incidents'','||old_version||')',
   'new.agreement_version in (''rentmect-master-v2026-11-23-speed-incidents'','||old_version||','||new_version||')');
 execute replace(d,marker,$check$or (new.agreement_version='rentmect-master-v2026-11-24-excessive-speeding' and
   strpos(coalesce(new.agreement_snapshot,''),'Excessive Speeding Fee: $25 per distinct occurrence of driving at 90 mph or faster.')=0)
   $check$||marker);
 d := pg_get_functiondef('public.guard_new_agreement_late_charge()'::regprocedure);
 if strpos(d,old_version||')')=0 then raise exception 'Unexpected return grace guard'; end if;
 execute replace(d,old_version||')', old_version||','||new_version||')');
end $$;

alter table public.rental_driving_incidents drop constraint rental_driving_incidents_check,
 add check(coalesce(peak_mph>=90,false) or reckless);

-- Earlier signed agreements counted speeding incidents strictly above 90 mph.
do $$ declare d text:=pg_get_functiondef('public.record_rental_driving_incident(uuid,text,numeric,boolean)'::regprocedure);
 marker text:='  insert into rental_driving_incidents('; begin
 if strpos(d,marker)=0 then raise exception 'Unexpected driving incident recorder'; end if;
 execute replace(d,marker,$guard$  if not p_reckless and p_peak_mph<=90 and r.agreement_version is distinct from 'rentmect-master-v2026-11-24-excessive-speeding' then
    raise exception 'This rental agreement counts speeds above 90 mph.';
  end if;
$guard$||marker);
end $$;

create function public.check_excessive_speeding_fee() returns trigger
language plpgsql set search_path=public as $$
begin
 if new.amount is distinct from 25 then raise exception 'The excessive speeding fee is $25.'; end if;
 if not exists(select 1 from public.rentals where id=new.rental_id and agreement_signed
   and agreement_version='rentmect-master-v2026-11-24-excessive-speeding'
   and strpos(agreement_snapshot,'Excessive Speeding Fee: $25 per distinct occurrence of driving at 90 mph or faster.')>0) then
   raise exception 'This rental has no signed agreement authorizing the excessive speeding fee.';
 end if;
 new.description := lower(trim(new.description));
 if not exists(select 1 from public.rental_driving_incidents i join public.rentals r on r.id=i.rental_id
   where i.rental_id=new.rental_id and i.incident_reference=new.description and i.peak_mph>=90
   and i.recorded_at>=r.agreement_signed_at) then
   raise exception 'Record the 90+ mph occurrence under Driving incidents and enter its incident report or trip event ID.';
 end if;
 return new;
end $$;
create trigger check_excessive_speeding_fee before insert or update of amount,rental_id,description,charge_type on public.rental_charge_items
for each row when(new.charge_type='excessive_speeding') execute function public.check_excessive_speeding_fee();
create unique index rental_excessive_speeding_fee_once on public.rental_charge_items(rental_id,lower(trim(description))) where charge_type='excessive_speeding';
commit;
