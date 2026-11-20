-- Record actual changes of queue membership independently of subsequent rental edits.
create function public.rentmect_closed_tab(r public.rentals) returns text
language sql stable set search_path=public as $$
 select case when public.rentmect_needs_deposit_review(r) then 'deposit_review'
   when r.status in ('completed','cancelled') and not public.rentmect_needs_deposit_review(r) then 'archive' end
$$;

create table public.rental_closed_tab_entries (
 rental_id uuid primary key references public.rentals(id) on delete cascade,
 tab text not null check (tab in ('deposit_review','archive')),
 entered_at timestamptz
);
alter table public.rental_closed_tab_entries enable row level security;
revoke all on public.rental_closed_tab_entries from public, anon, authenticated;
grant select on public.rental_closed_tab_entries to authenticated;
create policy rental_staff_read_closed_tab on public.rental_closed_tab_entries for select to authenticated
 using (public.is_admin() and public.rentmect_has_permission('tab.rentals'));

create function public.track_closed_rental_tab() returns trigger
language plpgsql security definer set search_path=public as $$
declare destination text := public.rentmect_closed_tab(new);
begin
 if tg_op='UPDATE' and destination is not distinct from public.rentmect_closed_tab(old) then return null; end if;
 if destination is null then
   delete from public.rental_closed_tab_entries where rental_id=new.id;
 else
   insert into public.rental_closed_tab_entries values (new.id,destination,statement_timestamp())
   on conflict (rental_id) do update set tab=excluded.tab,entered_at=excluded.entered_at;
 end if;
 return null;
end $$;
revoke all on function public.track_closed_rental_tab() from public,anon,authenticated;
create trigger rentals_track_closed_tab after insert or update on public.rentals
 for each row execute function public.track_closed_rental_tab();

-- Seed existing queues from the most recent audited transition into their current tab.
-- Records predating damage holds have the same default as the column migration.
with transitions as materialized (
 select a.entity_id, a.created_at, public.rentmect_closed_tab(n) as destination
 from public.admin_audit_logs a
 cross join lateral jsonb_populate_record(null::public.rentals,'{"damage_deposit_hold":false}'::jsonb || a.new_values) n
 cross join lateral jsonb_populate_record(null::public.rentals,'{"damage_deposit_hold":false}'::jsonb || coalesce(a.old_values,'{}'::jsonb)) o
 where a.entity_type='rental' and a.action in ('rental.update','rental.insert')
 and public.rentmect_closed_tab(n) is distinct from public.rentmect_closed_tab(o)
)
insert into public.rental_closed_tab_entries(rental_id,tab,entered_at)
select r.id,public.rentmect_closed_tab(r),coalesce(
 (select max(t.created_at) from transitions t where t.entity_id=r.id::text and t.destination=public.rentmect_closed_tab(r)),
 case when r.status='cancelled' then coalesce(r.cancelled_at,r.cancelled_before_pickup_at)
 when public.rentmect_closed_tab(r)='archive' then greatest(r.inspection_completed_at,r.deposit_released_at,r.deposit_held_reviewed_at)
 else r.inspection_completed_at end)
from public.rentals r where public.rentmect_closed_tab(r) is not null;

do $patch$
declare sig regprocedure; d text;
 projection text := 'case when r.status=''cancelled'' then coalesce(r.cancelled_at,r.cancelled_before_pickup_at) else r.inspection_completed_at end as closed_at';
begin
 foreach sig in array array['public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure,
 'public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[])'::regprocedure] loop
   d:=pg_get_functiondef(sig);
   if position(projection in d)=0 or position('from public.rentals r' in d)=0 then raise exception 'Unexpected rental list definition for %',sig; end if;
   d:=replace(d,projection,'entry.entered_at as closed_at');
   execute replace(d,'from public.rentals r','from public.rentals r left join public.rental_closed_tab_entries entry on entry.rental_id=r.id');
 end loop;
end $patch$;
