begin;
create or replace function public.rentmect_is_rental_overdue(p_status text,p_return_date date,p_return_time text)
returns boolean language sql stable set search_path=public as $$
  select lower(coalesce(p_status,'')) in ('active','rented','overdue') and p_return_date is not null
    and now() > (rentmect_rental_timestamp(p_return_date,p_return_time) at time zone 'America/New_York') + interval '2 hours'
$$;
do $$ declare d text:=pg_get_functiondef('public.reconcile_overdue_rentals()'::regprocedure);
begin
  if position('interval ''0 hours''' in d)=0 or position('''grace_period_minutes'', 0' in d)=0 then
    raise exception 'Review overdue reconciler before applying return grace.'; end if;
  execute replace(replace(d,'interval ''0 hours''','interval ''2 hours'''),'''grace_period_minutes'', 0','''grace_period_minutes'', 120');
end $$;
create function public.guard_new_agreement_late_charge() returns trigger language plpgsql security definer set search_path=public as $$
declare r rentals; cutoff timestamptz;
begin
  select * into strict r from rentals where id=new.rental_id;
  if r.agreement_version='rentmect-master-v2026-11-23-speed-incidents' then
    cutoff:=(rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') + interval '2 hours';
    if coalesce(r.inspection_completed_at,now())<=cutoff then raise exception 'The two-hour return grace period had not elapsed.'; end if;
  end if;
  return new;
end $$;
create trigger guard_new_agreement_late_charge before insert on public.rental_charge_items
for each row when (new.charge_type in ('late_fee','late_rental_day')) execute function public.guard_new_agreement_late_charge();
commit;
