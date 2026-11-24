begin;
create table public.rental_driving_incidents (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id),
  incident_reference text not null check(length(incident_reference) between 1 and 120),
  peak_mph numeric(5,1) check(peak_mph>0 and peak_mph<400),
  reckless boolean not null default false,
  recorded_by uuid not null references auth.users(id),
  recorded_at timestamptz not null default now(),
  unique(rental_id,incident_reference),
  check(coalesce(peak_mph>90,false) or reckless)
);
alter table public.rental_driving_incidents enable row level security;
revoke all on public.rental_driving_incidents from public,anon,authenticated;
grant select on public.rental_driving_incidents to authenticated;
create policy operations_read_driving_incidents on public.rental_driving_incidents for select to authenticated
using ((select public.rental_operations_staff_name()) is not null);

create function public.record_rental_driving_incident(p_rental_id uuid,p_reference text,p_peak_mph numeric,p_reckless boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r rentals; i rental_driving_incidents; incidents integer; ref text:=lower(trim(p_reference));
begin
  if rental_operations_staff_name() is null then raise exception 'Rental operations access required.' using errcode='42501'; end if;
  select * into strict r from rentals where id=p_rental_id for update;
  if r.status not in ('active','rented','overdue','return_initiated') then raise exception 'Choose a rental with the vehicle out.'; end if;
  insert into rental_driving_incidents(rental_id,incident_reference,peak_mph,reckless,recorded_by)
  values(r.id,ref,p_peak_mph,p_reckless,auth.uid()) on conflict(rental_id,incident_reference) do nothing;
  select * into strict i from rental_driving_incidents where rental_id=r.id and incident_reference=ref;
  if i.peak_mph is distinct from round(p_peak_mph,1) or i.reckless is distinct from p_reckless then
    raise exception 'This incident reference already exists with different details.'; end if;
  select count(*) into incidents from rental_driving_incidents where rental_id=r.id;
  return jsonb_build_object('count',incidents,'requires_review',incidents>=3 or coalesce(i.peak_mph>100,false));
end $$;
revoke all on function public.record_rental_driving_incident(uuid,text,numeric,boolean) from public,anon;
grant execute on function public.record_rental_driving_incident(uuid,text,numeric,boolean) to authenticated;
commit;
