-- Baseline exported from production 2026-11-13. Preserve merchant verification,
-- deposit review and all existing authorization/filter rules.
begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
do $$ begin
 if (select md5(prosrc) from pg_proc where oid='public.admin_rental_list(text,text,integer,integer,uuid)'::regprocedure) <> 'daab9335e7ad19a908878858a213300d' then
  raise exception 'Production rental-list baseline changed; review before applying';
 end if;
end $$;
-- Small-table index builds are bounded by the lock/statement timeouts above.
create index if not exists rental_documents_user_license_latest_speed on public.rental_documents(user_id,created_at desc,id desc) where document_type='license';
create index if not exists rental_documents_rental_type_latest_speed on public.rental_documents(rental_id,document_type,created_at desc,id desc);
create index if not exists rental_documents_initial_insurance_speed on public.rental_documents(rental_id,created_at desc,id desc) where document_type='insurance' and extension_request_id is null;
create index if not exists vehicle_reports_open_rental_speed on public.vehicle_reports(rental_id) where lower(coalesce(status,'open')) in ('open','pending','new');
CREATE OR REPLACE FUNCTION public.admin_rental_list(p_filter text DEFAULT 'needs_action'::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25, p_rental_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
    raise exception 'Rental access is required.' using errcode='42501'; end if;
  if p_filter is null or p_filter not in ('needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive','deposit_review') then
    raise exception 'Unknown rental filter.'; end if;
  if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>50 then raise exception 'Invalid rental page.'; end if;
  with base as materialized (
    select r.id,r.created_at,r.updated_at,r.user_id,r.vehicle_id,r.status,r.payment_status,r.deposit_status,
      public.rentmect_needs_deposit_review(r) as deposit_review,r.inspection_completed_at as return_completed_at,r.ending_mileage,r.deposit_review_note,r.deposit_review_follow_up_at,r.pickup_date,r.pickup_time,r.return_date,r.return_time,r.rental_total,r.security_deposit,
      coalesce(p.full_name,r.customer_name_snapshot,'Customer') as customer_name,v.name as vehicle_name,
      concat_ws(' ',v.name,p.full_name,p.phone,p.intended_vehicle_use,p.email,r.status,r.booking_source,r.merchant_reservation_number) as search_text,
      r.status in ('completed','cancelled') as terminal,
      r.status in ('active','rented','overdue','return_initiated') as vehicle_out,
      r.status in ('active','overdue','return_initiated') as cars_out,
      (r.status='overdue' or (r.status in ('active','rented') and
        (public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')+interval '3 hours'<=now())) as overdue,
      coalesce(v.status in ('maintenance','unavailable','inactive'),false) as maintenance,
      exists(select 1 from public.rental_extension_requests e where e.rental_id=r.id and e.status in ('pending','approved_pending_payment')) as open_extension,
      exists(select 1 from public.vehicle_reports x where x.rental_id=r.id and lower(coalesce(x.status,'open')) in ('open','pending','new')) as open_report,
      exists(select 1 from public.rental_emergency_exceptions x where x.rental_id=r.id and x.status='active' and x.expires_at>now()) as emergency,
      exists(select 1 from public.rental_charge_items c where c.rental_id=r.id and not coalesce(c.included_in_initial_payment,false)
        and c.charge_type is distinct from 'rental_installment' and c.status in ('pending','checkout_open','failed')) as outstanding_charge,
      coalesce((p.phone_verified or (r.merchant_id is null and p.phone_verified_at is not null)) and (case when r.merchant_id is not null then coalesce((public.get_customer_merchant_verification(r.id)->>'verified')::boolean,false) else p.identity_verification_status='verified' end)
        and r.vehicle_id is not null and r.pickup_date is not null and r.return_date is not null
        and r.agreement_signed and coalesce(r.payment_status,'pending')='paid'
        and (coalesce(r.security_deposit,0)=0 or (r.deposit_status='held' or (r.merchant_id is null and r.deposit_status in ('waived','released','transferred','release_pending','adjustment_refund_due'))))
        and license.status='approved' and insurance.approved,false) as release_ready
    from public.rentals r
    left join public.profiles p on p.id=r.user_id
    left join public.vehicles v on v.id=r.vehicle_id
    left join lateral (
      select d.status from public.rental_documents d where d.document_type='license'
        and (d.rental_id=r.id or d.id=(select x.id from public.rental_documents x where x.user_id=r.user_id
          and x.document_type='license' order by x.created_at desc,x.id desc limit 1))
      order by d.created_at desc,d.id desc limit 1
    ) license on not (r.status in ('completed','cancelled'))
    left join lateral (
      select bool_and(d.status='approved') and (bool_or(coalesce(d.insurance_coverage_type,'combined')='combined') or
        (bool_or(d.insurance_coverage_type='liability') and bool_or(d.insurance_coverage_type='collision'))) as approved
      from public.rental_documents d where d.rental_id=r.id and d.document_type='insurance' and d.extension_request_id is null
        and coalesce(d.insurance_packet_id,d.id)=(select coalesce(x.insurance_packet_id,x.id) from public.rental_documents x
          where x.rental_id=r.id and x.document_type='insurance' and x.extension_request_id is null
          order by x.created_at desc,x.id desc limit 1)
    ) insurance on not (r.status in ('completed','cancelled'))
    where (r.status in ('completed','cancelled') or r.payment_status in ('paid','partial','partial_paid','partially_paid') or r.deposit_status='held'
      or r.paid_at is not null or r.status in ('documents_needed','document_review','ready_for_pickup','approved','active','overdue','return_initiated'))
      or r.id=p_rental_id
  ), classified as materialized (
    select b.*, jsonb_build_object(
      'archive',terminal and not deposit_review,'deposit_review',deposit_review,'all',not terminal,'cars_out',cars_out,
      'returns_today',cars_out and return_date=(now() at time zone 'America/New_York')::date,
      'extensions',open_extension,'maintenance',maintenance,
      'ready_pickup',release_ready and status not in ('active','overdue','return_initiated','completed','cancelled'),
      'needs_action',not terminal and (open_extension or open_report or emergency or outstanding_charge or status='return_initiated'
        or overdue or coalesce(payment_status,'pending')<>'paid' or (not vehicle_out and not release_ready))) as matches
    from base b
  ), matching as materialized (
    select * from classified where case when p_rental_id is not null then id=p_rental_id else
      (matches->>p_filter)::boolean and (nullif(trim(left(coalesce(p_search,''),120)),'') is null
        or strpos(lower(search_text),lower(trim(left(p_search,120))))>0) end
  ), page as (
    select * from matching order by case when p_filter='deposit_review' then return_completed_at end asc nulls last,created_at desc,id desc offset p_offset limit p_limit
  )
  select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(page)-array['search_text','matches'] order by case when p_filter='deposit_review' then return_completed_at end asc nulls last,created_at desc,id desc) from page),'[]'::jsonb),
    'total',(select count(*) from matching),'offset',p_offset,'limit',p_limit,
    'counts',(select case when count(*)=0 then null else jsonb_build_object('archive',count(*) filter(where (matches->>'archive')::boolean), 'deposit_review',count(*) filter(where (matches->>'deposit_review')::boolean), 'all',count(*) filter(where (matches->>'all')::boolean), 'cars_out',count(*) filter(where (matches->>'cars_out')::boolean), 'returns_today',count(*) filter(where (matches->>'returns_today')::boolean), 'extensions',count(*) filter(where (matches->>'extensions')::boolean), 'maintenance',count(*) filter(where (matches->>'maintenance')::boolean), 'ready_pickup',count(*) filter(where (matches->>'ready_pickup')::boolean), 'needs_action',count(*) filter(where (matches->>'needs_action')::boolean)) end from classified)) into result;
  return result;
end; $function$;
CREATE OR REPLACE FUNCTION public.admin_rental_summary_changes(p_filter text DEFAULT 'needs_action'::text, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25, p_rental_id uuid DEFAULT NULL::uuid, p_changed_ids uuid[] DEFAULT '{}'::uuid[], p_known_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
    raise exception 'Rental access is required.' using errcode='42501'; end if;
  if p_filter is null or p_filter not in ('needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive','deposit_review') then
    raise exception 'Unknown rental filter.'; end if;
  if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>500 or cardinality(p_changed_ids)>500 or cardinality(p_known_ids)>500 then raise exception 'Invalid rental page.'; end if;
  with base as materialized (
    select r.id,r.created_at,r.updated_at,r.user_id,r.vehicle_id,r.status,r.payment_status,r.deposit_status,
      public.rentmect_needs_deposit_review(r) as deposit_review,r.inspection_completed_at as return_completed_at,r.ending_mileage,r.deposit_review_note,r.deposit_review_follow_up_at,r.pickup_date,r.pickup_time,r.return_date,r.return_time,r.rental_total,r.security_deposit,
      coalesce(p.full_name,r.customer_name_snapshot,'Customer') as customer_name,v.name as vehicle_name,
      concat_ws(' ',v.name,p.full_name,p.phone,p.intended_vehicle_use,p.email,r.status,r.booking_source,r.merchant_reservation_number) as search_text,
      r.status in ('completed','cancelled') as terminal,
      r.status in ('active','rented','overdue','return_initiated') as vehicle_out,
      r.status in ('active','overdue','return_initiated') as cars_out,
      (r.status='overdue' or (r.status in ('active','rented') and
        (public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York')+interval '3 hours'<=now())) as overdue,
      coalesce(v.status in ('maintenance','unavailable','inactive'),false) as maintenance,
      exists(select 1 from public.rental_extension_requests e where e.rental_id=r.id and e.status in ('pending','approved_pending_payment')) as open_extension,
      exists(select 1 from public.vehicle_reports x where x.rental_id=r.id and lower(coalesce(x.status,'open')) in ('open','pending','new')) as open_report,
      exists(select 1 from public.rental_emergency_exceptions x where x.rental_id=r.id and x.status='active' and x.expires_at>now()) as emergency,
      exists(select 1 from public.rental_charge_items c where c.rental_id=r.id and not coalesce(c.included_in_initial_payment,false)
        and c.charge_type is distinct from 'rental_installment' and c.status in ('pending','checkout_open','failed')) as outstanding_charge,
      coalesce((p.phone_verified or (r.merchant_id is null and p.phone_verified_at is not null)) and (case when r.merchant_id is not null then coalesce((public.get_customer_merchant_verification(r.id)->>'verified')::boolean,false) else p.identity_verification_status='verified' end)
        and r.vehicle_id is not null and r.pickup_date is not null and r.return_date is not null
        and r.agreement_signed and coalesce(r.payment_status,'pending')='paid'
        and (coalesce(r.security_deposit,0)=0 or (r.deposit_status='held' or (r.merchant_id is null and r.deposit_status in ('waived','released','transferred','release_pending','adjustment_refund_due'))))
        and license.status='approved' and insurance.approved,false) as release_ready
    from public.rentals r
    left join public.profiles p on p.id=r.user_id
    left join public.vehicles v on v.id=r.vehicle_id
    left join lateral (
      select d.status from public.rental_documents d where d.document_type='license'
        and (d.rental_id=r.id or d.id=(select x.id from public.rental_documents x where x.user_id=r.user_id
          and x.document_type='license' order by x.created_at desc,x.id desc limit 1))
      order by d.created_at desc,d.id desc limit 1
    ) license on not (r.status in ('completed','cancelled'))
    left join lateral (
      select bool_and(d.status='approved') and (bool_or(coalesce(d.insurance_coverage_type,'combined')='combined') or
        (bool_or(d.insurance_coverage_type='liability') and bool_or(d.insurance_coverage_type='collision'))) as approved
      from public.rental_documents d where d.rental_id=r.id and d.document_type='insurance' and d.extension_request_id is null
        and coalesce(d.insurance_packet_id,d.id)=(select coalesce(x.insurance_packet_id,x.id) from public.rental_documents x
          where x.rental_id=r.id and x.document_type='insurance' and x.extension_request_id is null
          order by x.created_at desc,x.id desc limit 1)
    ) insurance on not (r.status in ('completed','cancelled'))
    where (r.status in ('completed','cancelled') or r.payment_status in ('paid','partial','partial_paid','partially_paid') or r.deposit_status='held'
      or r.paid_at is not null or r.status in ('documents_needed','document_review','ready_for_pickup','approved','active','overdue','return_initiated'))
      or r.id=p_rental_id
  ), classified as materialized (
    select b.*, jsonb_build_object(
      'archive',terminal and not deposit_review,'deposit_review',deposit_review,'all',not terminal,'cars_out',cars_out,
      'returns_today',cars_out and return_date=(now() at time zone 'America/New_York')::date,
      'extensions',open_extension,'maintenance',maintenance,
      'ready_pickup',release_ready and status not in ('active','overdue','return_initiated','completed','cancelled'),
      'needs_action',not terminal and (open_extension or open_report or emergency or outstanding_charge or status='return_initiated'
        or overdue or coalesce(payment_status,'pending')<>'paid' or (not vehicle_out and not release_ready))) as matches
    from base b
  ), matching as materialized (
    select * from classified where case when p_rental_id is not null then id=p_rental_id else
      (matches->>p_filter)::boolean and (nullif(trim(left(coalesce(p_search,''),120)),'') is null
        or strpos(lower(search_text),lower(trim(left(p_search,120))))>0) end
  ), page as (
    select * from matching order by case when p_filter='deposit_review' then return_completed_at end asc nulls last,created_at desc,id desc offset p_offset limit p_limit
  )
  select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(page)-array['search_text','matches'] order by case when p_filter='deposit_review' then return_completed_at end asc nulls last,created_at desc,id desc) from page where id=any(coalesce(p_changed_ids,'{}'::uuid[])) or not(id=any(coalesce(p_known_ids,'{}'::uuid[])))),'[]'::jsonb),
    'visible_ids',coalesce((select jsonb_agg(id order by case when p_filter='deposit_review' then return_completed_at end asc nulls last,created_at desc,id desc) from page),'[]'::jsonb),
    'total',(select count(*) from matching),'offset',p_offset,'limit',p_limit,
    'counts',(select case when count(*)=0 then null else jsonb_build_object('archive',count(*) filter(where (matches->>'archive')::boolean), 'deposit_review',count(*) filter(where (matches->>'deposit_review')::boolean), 'all',count(*) filter(where (matches->>'all')::boolean), 'cars_out',count(*) filter(where (matches->>'cars_out')::boolean), 'returns_today',count(*) filter(where (matches->>'returns_today')::boolean), 'extensions',count(*) filter(where (matches->>'extensions')::boolean), 'maintenance',count(*) filter(where (matches->>'maintenance')::boolean), 'ready_pickup',count(*) filter(where (matches->>'ready_pickup')::boolean), 'needs_action',count(*) filter(where (matches->>'needs_action')::boolean)) end from classified)) into result;
  return result;
end; $function$;
revoke all on function public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[]) from public,anon;
grant execute on function public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
