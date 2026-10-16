begin;
-- Read-only quick lookup shares the exact same historical matcher as saved cases.
create function public.ticket_candidate_result(c public.ticket_cases) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare lo timestamptz; hi timestamptz; vids uuid[]; plate_vids uuid[]; rows jsonb; suggestions jsonb; result jsonb;
begin

 lo:=coalesce(c.occurred_at,c.violation_date::timestamp at time zone c.timezone);
 hi:=case when c.occurred_at is null then (c.violation_date+1)::timestamp at time zone c.timezone else c.occurred_at+interval '1 microsecond' end;
 select array_agg(distinct a.vehicle_id) into plate_vids from tollspot_plate_assignments a
 where regexp_replace(upper(a.plate_number),'[^A-Z0-9]','','g')=regexp_replace(c.plate_number,'[^A-Z0-9]','','g')
 and upper(a.plate_state)=c.plate_state and a.assigned_at<hi and coalesce(a.removed_at,'infinity')>lo;
 vids:=case when c.vehicle_id is not null then array[c.vehicle_id] else coalesce(plate_vids,'{}'::uuid[]) end;
 -- A current plate is a suggestion only, never historical proof.
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'plate_number',plate_number)),'[]') into suggestions from vehicles
 where c.plate_number<>'' and regexp_replace(upper(plate_number),'[^A-Z0-9]','','g')=regexp_replace(c.plate_number,'[^A-Z0-9]','','g') and upper(plate_state)=c.plate_state;
 with periods as (
  select r.id rental_id,a.vehicle_id,greatest(a.assigned_from,rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York') starts_at,
   case when a.id=(select last_a.id from rental_vehicle_assignments last_a where last_a.rental_id=r.id order by assigned_from desc,created_at desc,id desc limit 1)
    then coalesce(r.inspection_completed_at,case when r.status in ('active','rented','overdue','return_initiated') then 'infinity'::timestamptz else a.assigned_until end,a.assigned_until)
    else a.assigned_until end ends_at,a.source,false fallback
  from rentals r join rental_vehicle_assignments a on a.rental_id=r.id where a.vehicle_id=any(vids)
  union all
  select r.id,r.vehicle_id,rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York',
   coalesce(r.inspection_completed_at,case when r.status in ('active','rented','overdue','return_initiated') then 'infinity'::timestamptz else rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York' end),'booked_dates',true
  from rentals r where r.vehicle_id=any(vids) and not exists(select 1 from rental_vehicle_assignments a where a.rental_id=r.id)
 ), matches as (
  select r.id,r.user_id,p.full_name,p.email,p.phone,r.status,r.starting_mileage,
   r.pickup_date,r.pickup_time,r.return_date,r.return_time,r.inspection_completed_at,
   jsonb_agg(jsonb_build_object('vehicle_id',per.vehicle_id,'vehicle_name',v.name,'from',per.starts_at,'until',per.ends_at,'source',per.source,'booked_fallback',per.fallback) order by per.starts_at) intervals,
   bool_or(per.fallback or per.source in ('initial','admin_edit')) booked_fallback,
   (r.starting_mileage is not null or r.status in ('active','rented','overdue','return_initiated','completed','returned')) eligible
  from periods per join rentals r on r.id=per.rental_id join profiles p on p.id=r.user_id join vehicles v on v.id=per.vehicle_id
  where r.status not in ('cancelled','canceled') and per.starts_at<hi and coalesce(per.ends_at,'infinity')>lo
  group by r.id,p.id
 ) select coalesce(jsonb_agg(to_jsonb(m) order by m.pickup_date,m.id),'[]') into rows from matches m;
 result:=jsonb_build_object('candidates',rows,'plate_vehicle_ids',coalesce(to_jsonb(plate_vids),'[]'),'current_plate_suggestions',suggestions,
 'vehicle_verification_required',c.vehicle_id is not null and c.plate_number<>'' and (coalesce(cardinality(plate_vids),0)<>1 or not c.vehicle_id=any(coalesce(plate_vids,'{}'::uuid[]))),
 'time_unknown',c.violation_time is null,'window_start',lo,'window_end',hi,'version',c.version);
 return result||jsonb_build_object('token',md5(result::text));
end$$;


create or replace function public.admin_ticket_candidates(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare c ticket_cases%rowtype;
begin
 perform ticket_require(); select * into c from ticket_cases where id=p_id;
 if not found then raise exception 'Ticket not found.'; end if;
 return ticket_candidate_result(c);
end$$;
create function public.admin_ticket_lookup(p_data jsonb) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare c ticket_cases%rowtype; options timestamptz[];
begin
 perform ticket_require();
 c.vehicle_id:=nullif(p_data->>'vehicle_id','')::uuid;
 c.plate_number:=upper(trim(coalesce(p_data->>'plate_number','')));
 c.plate_state:=upper(trim(coalesce(nullif(p_data->>'plate_state',''),'CT')));
 c.violation_date:=nullif(p_data->>'violation_date','')::date;
 c.violation_time:=nullif(p_data->>'violation_time','')::time;
 c.timezone:=coalesce(nullif(p_data->>'timezone',''),'America/New_York');
 c.occurred_at:=nullif(p_data->>'occurred_at','')::timestamptz;
 if c.violation_date is null or (c.vehicle_id is null and c.plate_number='') then raise exception 'Choose a car or enter a plate, and enter the ticket date.'; end if;
 options:=ticket_time_options(c.violation_date,c.violation_time,c.timezone);
 if c.violation_time is not null then
  if cardinality(options)=1 then c.occurred_at:=options[1];
  elsif c.occurred_at is null or not c.occurred_at=any(options) then raise exception 'Check the time and timezone: this clock time is missing or occurs twice.'; end if;
 else c.occurred_at:=null; end if;
 return ticket_candidate_result(c);
end$$;
alter table public.ticket_cases add column customer_flag_active boolean not null default false,
 add column customer_flag_note text, add column customer_flag_by uuid references auth.users(id), add column customer_flag_at timestamptz;
alter table public.ticket_cases add constraint ticket_flag_confirmed check(not customer_flag_active or (rental_id is not null and confirmed_at is not null));
create function public.ticket_clear_changed_flag() returns trigger language plpgsql security definer set search_path=public as $$begin
 if old.customer_flag_active and (new.rental_id is distinct from old.rental_id or new.confirmed_at is null) then
  new.customer_flag_active:=false;
  perform ticket_log(old.id,'customer_flag_cleared','Renter match changed; review before flagging again.',jsonb_build_object('previous_rental_id',old.rental_id));
 end if;
 return new;
end$$;
create trigger ticket_clear_changed_flag before update on public.ticket_cases for each row execute function public.ticket_clear_changed_flag();
create function public.admin_ticket_customer_flag(p_id uuid,p_version integer,p_active boolean,p_note text) returns jsonb
language plpgsql security definer set search_path=public as $$declare c ticket_cases%rowtype; begin
 perform ticket_require(true);
 if not coalesce(rentmect_has_permission('customer.manage'),false) then raise exception 'Customer management permission is required.' using errcode='42501'; end if;
 select * into c from ticket_cases where id=p_id for update;
 if not found then raise exception 'Ticket not found.'; end if;
 if c.version is distinct from p_version then raise exception 'This ticket changed. Reload it before continuing.' using errcode='40001'; end if;
 if p_active is null or length(trim(coalesce(p_note,'')))<10 then raise exception 'Enter a reason of at least 10 characters.'; end if;
 if p_active and (c.rental_id is null or c.confirmed_at is null) then raise exception 'Confirm the renter before adding a customer flag.'; end if;
 update ticket_cases set customer_flag_active=p_active,customer_flag_note=trim(p_note),customer_flag_by=auth.uid(),customer_flag_at=now(),version=version+1,updated_at=now(),updated_by=auth.uid() where id=p_id returning * into c;
 perform ticket_log(p_id,case when p_active then 'customer_flag_added' else 'customer_flag_cleared' end,trim(p_note),jsonb_build_object('rental_id',c.rental_id));
 return to_jsonb(c);
end$$;
-- Minimum case summary for staff reviewing customers, bookings, or rentals.
create function public.admin_ticket_customer_flags(p_user_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path=public as $$begin
 if auth.uid() is null or not (coalesce(rentmect_has_permission('tab.tickets'),false) or coalesce(rentmect_has_permission('tab.rentals'),false) or coalesce(rentmect_has_permission('tab.customers'),false) or coalesce(rentmect_has_permission('booking.create'),false)) then raise exception 'Staff access is required.' using errcode='42501'; end if;
 if cardinality(p_user_ids)>500 then raise exception 'Request at most 500 customers.'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'user_id',r.user_id,'rental_id',c.rental_id,'ticket_number',c.ticket_number,'amount',c.amount,'violation_date',c.violation_date,'note',c.customer_flag_note) order by c.customer_flag_at desc),'[]') from ticket_cases c join rentals r on r.id=c.rental_id where c.customer_flag_active and r.user_id=any(p_user_ids));
end$$;
revoke all on function public.ticket_candidate_result(public.ticket_cases),public.ticket_clear_changed_flag() from public,anon,authenticated;
revoke all on function public.admin_ticket_lookup(jsonb),public.admin_ticket_customer_flag(uuid,integer,boolean,text),public.admin_ticket_customer_flags(uuid[]) from public,anon,authenticated;
grant execute on function public.admin_ticket_lookup(jsonb),public.admin_ticket_customer_flag(uuid,integer,boolean,text),public.admin_ticket_customer_flags(uuid[]) to authenticated;
commit;
