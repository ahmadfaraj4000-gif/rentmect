begin;

insert into public.employee_permissions(permission_key,label,category,description,enabled) values
 ('tab.tickets','View Ticket Resolution','Visible tabs','View private ticket cases and historical rental candidates.',false),
 ('ticket.manage','Manage tickets','Rentals & bookings','Create and review ticket cases, evidence, and resolution records.',false)
on conflict(permission_key) do nothing;

create table public.ticket_cases (
 id uuid primary key default gen_random_uuid(),
 agency text not null check(length(trim(agency)) between 1 and 200),
 ticket_number text not null check(length(trim(ticket_number)) between 1 and 100),
 agency_key text generated always as (lower(regexp_replace(trim(agency),'\s+',' ','g'))) stored,
 ticket_key text generated always as (upper(regexp_replace(ticket_number,'[^a-zA-Z0-9]','','g'))) stored,
 ticket_type text not null default 'speeding',
 vehicle_id uuid references public.vehicles(id) on delete restrict,
 plate_number text not null default '', plate_state text not null default '',
 vehicle_note text not null default '',
 violation_date date not null, violation_time time, timezone text not null default 'America/New_York',
 occurred_at timestamptz, location text not null default '', amount numeric(12,2) check(amount>=0),
 issue_date date, received_date date, payment_deadline date, appeal_deadline date,
 notes text not null default '',
 rental_id uuid references public.rentals(id) on delete restrict,
 status text not null default 'needs_review' check(status in ('needs_review','matched','in_progress','resolved')),
 outcome text check(outcome in ('paid_to_agency','transferred','dismissed','closed_without_action')),
 paid_by text, resolution_note text,
 match_evidence jsonb, confirmed_by uuid references auth.users(id), confirmed_at timestamptz,
 version integer not null default 1,
 created_by uuid not null references auth.users(id), created_at timestamptz not null default now(),
 updated_by uuid not null references auth.users(id), updated_at timestamptz not null default now(),
 unique(agency_key,ticket_key), check(ticket_key<>''),
 check(vehicle_id is not null or (trim(plate_number)<>'' and trim(plate_state)<>'')),
 check((violation_time is null)=(occurred_at is null))
);
create index ticket_cases_deadline_idx on public.ticket_cases(status,(least(payment_deadline,appeal_deadline)));
create index ticket_cases_rental_idx on public.ticket_cases(rental_id);
create table public.ticket_activity (
 id uuid primary key default gen_random_uuid(), ticket_id uuid not null references public.ticket_cases(id) on delete restrict,
 actor_id uuid references auth.users(id), action text not null, note text not null default '',
 evidence jsonb not null default '{}', created_at timestamptz not null default now()
);
create index ticket_activity_case_idx on public.ticket_activity(ticket_id,created_at);
create table public.ticket_attachments (
 id uuid primary key, ticket_id uuid not null references public.ticket_cases(id) on delete restrict,
 file_name text not null, mime_type text not null, size_bytes bigint not null check(size_bytes between 1 and 20971520),
 object_path text not null unique, created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(), uploaded_at timestamptz, removed_at timestamptz
);
create index ticket_attachments_case_idx on public.ticket_attachments(ticket_id);

alter table public.ticket_cases enable row level security;
alter table public.ticket_activity enable row level security;
alter table public.ticket_attachments enable row level security;
revoke all on public.ticket_cases,public.ticket_activity,public.ticket_attachments from anon,authenticated;
grant select on public.ticket_cases,public.ticket_activity,public.ticket_attachments to authenticated;
create policy ticket_cases_read on public.ticket_cases for select to authenticated using(public.rentmect_has_permission('tab.tickets'));
create policy ticket_activity_read on public.ticket_activity for select to authenticated using(public.rentmect_has_permission('tab.tickets'));
create policy ticket_attachments_read on public.ticket_attachments for select to authenticated using(public.rentmect_has_permission('tab.tickets'));

create function public.ticket_require(p_manage boolean default false) returns void
language plpgsql security definer set search_path=public as $$begin
 if auth.uid() is null or not coalesce(public.rentmect_has_permission('tab.tickets'),false)
 or (p_manage and not coalesce(public.rentmect_has_permission('ticket.manage'),false)) then
 raise exception 'Ticket access is not permitted.' using errcode='42501'; end if;
end$$;

-- Validate local wall time on the server. DST folds require an explicitly selected instant.
create function public.ticket_time_options(p_date date,p_time time,p_zone text) returns timestamptz[]
language plpgsql stable set search_path=public as $$declare local_at timestamp:=p_date+p_time; options timestamptz[]; begin
 if not exists(select 1 from pg_timezone_names where name=p_zone) then raise exception 'Choose a valid IANA timezone.'; end if;
 if p_time is null then return '{}'::timestamptz[]; end if;
 select array_agg(candidate order by candidate) into options from (
  select distinct (local_at at time zone 'UTC') - ((sample at time zone p_zone)-(sample at time zone 'UTC')) as candidate
  from generate_series((local_at at time zone 'UTC')-interval '48 hours',(local_at at time zone 'UTC')+interval '48 hours',interval '6 hours') sample
 ) x where candidate at time zone p_zone=local_at;
 return coalesce(options,'{}'::timestamptz[]);
end$$;

create function public.ticket_log(p_id uuid,p_action text,p_note text default '',p_evidence jsonb default '{}') returns void
language plpgsql security definer set search_path=public as $$begin
 insert into ticket_activity(ticket_id,actor_id,action,note,evidence) values(p_id,auth.uid(),p_action,p_note,p_evidence);
 insert into admin_audit_logs(actor_user_id,actor_email,actor_role,action,entity_type,entity_id,metadata)
 select auth.uid(),p.email,p.staff_role,'ticket.'||p_action,'ticket_case',p_id::text,
 jsonb_build_object('note',p_note,'evidence',p_evidence) from profiles p where p.id=auth.uid();
end$$;

create function public.admin_ticket_save(p_id uuid,p_version integer,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare old ticket_cases%rowtype; n ticket_cases%rowtype; options timestamptz[]; reset_match boolean; duplicate_id uuid;
begin
 perform ticket_require(true);
 -- Serialize duplicate creation and edits by natural key; row revision protects edits.
 perform pg_advisory_xact_lock(hashtextextended(lower(regexp_replace(trim(p_data->>'agency'),'\s+',' ','g'))||':'||upper(regexp_replace(p_data->>'ticket_number','[^a-zA-Z0-9]','','g')),0));
 select * into old from ticket_cases where id=p_id for update;
 if found then
  if p_version is null then return jsonb_build_object('case',to_jsonb(old),'duplicate',true); end if;
  if old.version<>p_version then raise exception 'This ticket changed. Reload it before saving.' using errcode='40001'; end if;
  if old.status='resolved' then raise exception 'Reopen this ticket before editing it.'; end if;
 elsif p_version is not null then raise exception 'Ticket not found.'; end if;
 select id into duplicate_id from ticket_cases where agency_key=lower(regexp_replace(trim(p_data->>'agency'),'\s+',' ','g'))
 and ticket_key=upper(regexp_replace(p_data->>'ticket_number','[^a-zA-Z0-9]','','g')) and id<>p_id;
 if duplicate_id is not null then
  if old.id is not null then raise exception 'Another case already has this agency and ticket number.'; end if;
  return jsonb_build_object('case',(select to_jsonb(c) from ticket_cases c where id=duplicate_id),'duplicate',true);
 end if;
 n:=old;
 n.id:=p_id; n.agency:=trim(p_data->>'agency'); n.ticket_number:=trim(p_data->>'ticket_number');
 n.ticket_type:=coalesce(nullif(p_data->>'ticket_type',''),'speeding');
 n.vehicle_id:=nullif(p_data->>'vehicle_id','')::uuid; n.plate_number:=upper(trim(coalesce(p_data->>'plate_number','')));
 n.plate_state:=upper(trim(coalesce(p_data->>'plate_state',''))); n.vehicle_note:=trim(coalesce(p_data->>'vehicle_note',''));
 n.violation_date:=(p_data->>'violation_date')::date; n.violation_time:=nullif(p_data->>'violation_time','')::time;
 n.timezone:=coalesce(nullif(p_data->>'timezone',''),'America/New_York');
 options:=ticket_time_options(n.violation_date,n.violation_time,n.timezone);
 n.occurred_at:=nullif(p_data->>'occurred_at','')::timestamptz;
 if n.violation_time is null then n.occurred_at:=null;
 elsif cardinality(options)=0 then raise exception 'This local time does not exist because of a clock change.';
 elsif n.occurred_at is null and cardinality(options)=1 then n.occurred_at:=options[1];
 elsif n.occurred_at is null or not (n.occurred_at=any(options)) then raise exception 'Choose which occurrence of this local time the ticket means.'; end if;
 n.location:=coalesce(p_data->>'location',''); n.amount:=nullif(p_data->>'amount','')::numeric;
 n.issue_date:=nullif(p_data->>'issue_date','')::date; n.received_date:=nullif(p_data->>'received_date','')::date;
 n.payment_deadline:=nullif(p_data->>'payment_deadline','')::date; n.appeal_deadline:=nullif(p_data->>'appeal_deadline','')::date;
 n.notes:=coalesce(p_data->>'notes','');
 reset_match:=old.id is not null and row(old.vehicle_id,old.plate_number,old.plate_state,old.vehicle_note,old.violation_date,old.violation_time,old.timezone,old.occurred_at)
 is distinct from row(n.vehicle_id,n.plate_number,n.plate_state,n.vehicle_note,n.violation_date,n.violation_time,n.timezone,n.occurred_at);
 if old.id is null then
  insert into ticket_cases(id,agency,ticket_number,ticket_type,vehicle_id,plate_number,plate_state,vehicle_note,violation_date,violation_time,timezone,occurred_at,location,amount,issue_date,received_date,payment_deadline,appeal_deadline,notes,created_by,updated_by)
  values(n.id,n.agency,n.ticket_number,n.ticket_type,n.vehicle_id,n.plate_number,n.plate_state,n.vehicle_note,n.violation_date,n.violation_time,n.timezone,n.occurred_at,n.location,n.amount,n.issue_date,n.received_date,n.payment_deadline,n.appeal_deadline,n.notes,auth.uid(),auth.uid()) returning * into n;
 else
  update ticket_cases set agency=n.agency,ticket_number=n.ticket_number,ticket_type=n.ticket_type,vehicle_id=n.vehicle_id,plate_number=n.plate_number,plate_state=n.plate_state,vehicle_note=n.vehicle_note,
  violation_date=n.violation_date,violation_time=n.violation_time,timezone=n.timezone,occurred_at=n.occurred_at,location=n.location,amount=n.amount,
  issue_date=n.issue_date,received_date=n.received_date,payment_deadline=n.payment_deadline,appeal_deadline=n.appeal_deadline,notes=n.notes,
  rental_id=case when reset_match then null else old.rental_id end,match_evidence=case when reset_match then null else old.match_evidence end,
  confirmed_by=case when reset_match then null else old.confirmed_by end,confirmed_at=case when reset_match then null else old.confirmed_at end,
  status=case when reset_match then 'needs_review' else old.status end,version=old.version+1,updated_by=auth.uid(),updated_at=now()
  where id=p_id returning * into n;
 end if;
 perform ticket_log(p_id,case when old.id is null then 'created' when reset_match then 'edited_match_cleared' else 'edited' end,'',jsonb_build_object('before',to_jsonb(old),'after',to_jsonb(n)));
 return jsonb_build_object('case',to_jsonb(n),'duplicate',false);
end$$;

create function public.admin_ticket_vehicles(p_search text default '') returns jsonb
language plpgsql stable security definer set search_path=public as $$begin
 perform ticket_require();
 return (select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
  select id,name,plate_number,plate_state from vehicles
  where name ilike '%'||trim(p_search)||'%' or plate_number ilike '%'||trim(p_search)||'%'
  order by name,id limit 30
 ) x);
end$$;

create function public.admin_ticket_candidates(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare c ticket_cases%rowtype; lo timestamptz; hi timestamptz; vids uuid[]; plate_vids uuid[]; rows jsonb; suggestions jsonb; result jsonb;
begin
 perform ticket_require(); select * into c from ticket_cases where id=p_id;
 if not found then raise exception 'Ticket not found.'; end if;
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

create function public.admin_ticket_action(p_id uuid,p_version integer,p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public as $$
declare c ticket_cases%rowtype; matches jsonb; candidate jsonb; rid uuid; note text:=trim(coalesce(p_data->>'note','')); outcome_value text;
begin
 perform ticket_require(true); select * into c from ticket_cases where id=p_id for update;
 if not found then raise exception 'Ticket not found.'; end if;
 if c.version<>p_version then raise exception 'This ticket changed. Reload it before continuing.' using errcode='40001'; end if;
 if c.status='resolved' and p_action<>'reopen' then raise exception 'Reopen this ticket before changing it.'; end if;
 if p_action='confirm' then
  matches:=admin_ticket_candidates(p_id);
  if p_data->>'token' is distinct from matches->>'token' then raise exception 'Matching evidence changed. Find the renter again.' using errcode='40001'; end if;
  rid:=(p_data->>'rental_id')::uuid;
  select x into candidate from jsonb_array_elements(matches->'candidates') x where (x->>'id')::uuid=rid;
  if candidate is null or not (candidate->>'eligible')::boolean then raise exception 'Choose an eligible rental from the current candidates.'; end if;
  if (matches->>'vehicle_verification_required')::boolean and length(c.vehicle_note)<10 then raise exception 'Add a vehicle verification note explaining the plate history before confirming.'; end if;
  if ((matches->>'time_unknown')::boolean or jsonb_array_length(matches->'candidates')<>1 or (candidate->>'booked_fallback')::boolean
    or (matches->>'vehicle_verification_required')::boolean or jsonb_array_length(matches->'plate_vehicle_ids')>1) and length(note)<10 then
    raise exception 'Explain how you verified this uncertain match (at least 10 characters).'; end if;
  update ticket_cases set rental_id=rid,status='matched',confirmed_by=auth.uid(),confirmed_at=now(),
   match_evidence=jsonb_build_object('candidate',candidate,'search',matches,'verification_note',note,'vehicle_note',c.vehicle_note) where id=p_id;
 elsif p_action='start' then
  update ticket_cases set status='in_progress' where id=p_id;
 elsif p_action='resolve' then
  outcome_value:=p_data->>'outcome';
  if outcome_value is null or outcome_value not in ('paid_to_agency','transferred','dismissed','closed_without_action') or length(note)<3 then raise exception 'Choose an outcome and enter a resolution note.'; end if;
  if outcome_value='paid_to_agency' and length(trim(coalesce(p_data->>'paid_by','')))<2 then raise exception 'Identify who paid the agency.'; end if;
  if outcome_value='transferred' and c.rental_id is null then raise exception 'Confirm the rental before recording a transfer.'; end if;
  update ticket_cases set status='resolved',outcome=outcome_value,resolution_note=note,paid_by=case when outcome_value='paid_to_agency' then trim(p_data->>'paid_by') else null end where id=p_id;
 elsif p_action='reopen' then
  if c.status<>'resolved' or length(note)<3 then raise exception 'A resolved ticket and reopening reason are required.'; end if;
  update ticket_cases set status=case when rental_id is null then 'needs_review' else 'matched' end,outcome=null,paid_by=null,resolution_note=null where id=p_id;
 elsif p_action in ('note','renter_notified') then
  if length(note)<3 then raise exception 'Enter an activity note.'; end if;
 else raise exception 'Unknown ticket action.'; end if;
 update ticket_cases set version=version+1,updated_by=auth.uid(),updated_at=now() where id=p_id returning * into c;
 perform ticket_log(p_id,p_action,note,case when p_action='confirm' then c.match_evidence else p_data end);
 return to_jsonb(c);
end$$;

create function public.admin_ticket_list(p_search text default '',p_status text default 'unresolved',p_vehicle_id uuid default null,p_deadline text default '',p_offset integer default 0) returns jsonb
language plpgsql stable security definer set search_path=public as $$declare result jsonb; today date:=(now() at time zone 'America/New_York')::date; begin
 perform ticket_require();
 with filtered as (
  select c.id,c.agency,c.ticket_number,c.vehicle_id,c.plate_number,c.violation_date,c.violation_time,c.timezone,c.amount,c.status,c.rental_id,
   c.created_at,least(c.payment_deadline,c.appeal_deadline) next_deadline,v.name vehicle_name,p.full_name renter_name
  from ticket_cases c left join vehicles v on v.id=c.vehicle_id left join rentals r on r.id=c.rental_id left join profiles p on p.id=r.user_id
  where (p_status='all' or (p_status='unresolved' and c.status<>'resolved') or c.status=p_status)
   and (p_vehicle_id is null or c.vehicle_id=p_vehicle_id or exists(select 1 from rental_vehicle_assignments a where a.rental_id=c.rental_id and a.vehicle_id=p_vehicle_id))
   and (p_deadline='' or (c.status<>'resolved' and ((p_deadline='overdue' and least(c.payment_deadline,c.appeal_deadline)<today)
    or (p_deadline='week' and least(c.payment_deadline,c.appeal_deadline) between today and today+7))))
   and concat_ws(' ',c.agency,c.ticket_number,c.plate_number,v.name,p.full_name,p.email) ilike '%'||trim(p_search)||'%'
 ), page as (select * from filtered order by next_deadline nulls last,created_at desc,id limit 25 offset greatest(coalesce(p_offset,0),0))
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'),'total',(select count(*) from filtered)) into result;
 return result;
end$$;

create function public.admin_ticket_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$begin
 perform ticket_require();
 return (select jsonb_build_object('case',to_jsonb(c),'vehicle_name',v.name,
  'renter_name',p.full_name,'attachments',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from ticket_attachments a where a.ticket_id=c.id and a.removed_at is null),'[]'),
  'activity',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id) from (select a.*,p.full_name actor_name from ticket_activity a left join profiles p on p.id=a.actor_id where a.ticket_id=c.id) x),'[]'))
  from ticket_cases c left join vehicles v on v.id=c.vehicle_id left join rentals r on r.id=c.rental_id left join profiles p on p.id=r.user_id where c.id=p_id);
end$$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('ticket-evidence','ticket-evidence',false,20971520,array['application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif']);

create function public.admin_ticket_attachment(p_id uuid,p_attachment_id uuid,p_action text,p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path=public as $$declare a ticket_attachments%rowtype; c ticket_cases%rowtype; begin
 perform ticket_require(true); select * into c from ticket_cases where id=p_id for update;
 if not found then raise exception 'Ticket not found.'; end if;
 if c.status='resolved' then raise exception 'Reopen the ticket before changing attachments.'; end if;
 select * into a from ticket_attachments where id=p_attachment_id for update;
 if found and a.ticket_id<>p_id then raise exception 'Attachment belongs to another ticket.'; end if;
 if p_action='prepare' then
  if a.id is not null then return to_jsonb(a); end if;
  if p_data->>'mime_type' is null or p_data->>'mime_type' not in ('application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif') then raise exception 'Unsupported evidence format.'; end if;
  if length(trim(coalesce(p_data->>'file_name','')))=0 then raise exception 'File name is required.'; end if;
  insert into ticket_attachments(id,ticket_id,file_name,mime_type,size_bytes,object_path,created_by)
  values(p_attachment_id,p_id,left(p_data->>'file_name',250),p_data->>'mime_type',(p_data->>'size_bytes')::bigint,p_id::text||'/'||p_attachment_id::text,auth.uid()) returning * into a;
 elsif p_action='complete' then
  if a.id is null or a.removed_at is not null then raise exception 'Attachment not found.'; end if;
  if a.uploaded_at is not null then return to_jsonb(a); end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='ticket-evidence' and o.name=a.object_path and (o.metadata->>'size')::bigint=a.size_bytes and o.metadata->>'mimetype'=a.mime_type) then raise exception 'Upload is incomplete. Retry the file upload.'; end if;
  update ticket_attachments set uploaded_at=now() where id=a.id returning * into a;
  perform ticket_log(p_id,'attachment_added',a.file_name,jsonb_build_object('attachment_id',a.id));
 elsif p_action='remove' then
  if a.id is null then raise exception 'Attachment not found.'; end if;
  if a.removed_at is not null then return to_jsonb(a); end if;
  update ticket_attachments set removed_at=now() where id=a.id returning * into a;
  perform ticket_log(p_id,'attachment_removed',a.file_name,jsonb_build_object('attachment_id',a.id));
 else raise exception 'Unknown attachment action.'; end if;
 return to_jsonb(a);
end$$;

create policy ticket_evidence_read on storage.objects for select to authenticated using(
 bucket_id='ticket-evidence' and public.rentmect_has_permission('tab.tickets') and exists(
 select 1 from public.ticket_attachments a where a.object_path=name and a.removed_at is null and a.uploaded_at is not null));
create policy ticket_evidence_insert on storage.objects for insert to authenticated with check(
 bucket_id='ticket-evidence' and public.rentmect_has_permission('tab.tickets') and public.rentmect_has_permission('ticket.manage') and exists(
 select 1 from public.ticket_attachments a join public.ticket_cases c on c.id=a.ticket_id where a.object_path=name and a.removed_at is null and a.uploaded_at is null and c.status<>'resolved'));

-- Internal helpers are not callable through PostgREST; every exposed operation checks access.
revoke all on function public.ticket_require(boolean),public.ticket_time_options(date,time,text),public.ticket_log(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.admin_ticket_save(uuid,integer,jsonb),public.admin_ticket_vehicles(text),public.admin_ticket_candidates(uuid),public.admin_ticket_action(uuid,integer,text,jsonb),public.admin_ticket_list(text,text,uuid,text,integer),public.admin_ticket_detail(uuid),public.admin_ticket_attachment(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.admin_ticket_save(uuid,integer,jsonb),public.admin_ticket_vehicles(text),public.admin_ticket_candidates(uuid),public.admin_ticket_action(uuid,integer,text,jsonb),public.admin_ticket_list(text,text,uuid,text,integer),public.admin_ticket_detail(uuid),public.admin_ticket_attachment(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
