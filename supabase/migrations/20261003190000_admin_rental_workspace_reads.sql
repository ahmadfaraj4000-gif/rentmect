begin;

-- Read-only endpoints for the rental workspace. SECURITY INVOKER preserves
-- existing row policies, including staff financial visibility restrictions.
create function public.admin_rental_list(p_filter text default 'needs_action', p_search text default '',
  p_offset integer default 0, p_limit integer default 25, p_rental_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=public as $$
declare result jsonb;
begin
  if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
    raise exception 'Rental access is required.' using errcode='42501'; end if;
  if p_filter is null or p_filter not in ('needs_action','ready_pickup','cars_out','returns_today','extensions','maintenance','all','archive') then
    raise exception 'Unknown rental filter.'; end if;
  if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>50 then raise exception 'Invalid rental page.'; end if;
  with base as materialized (
    select r.id,r.created_at,r.updated_at,r.user_id,r.vehicle_id,r.status,r.payment_status,r.deposit_status,
      r.pickup_date,r.pickup_time,r.return_date,r.return_time,r.rental_total,r.security_deposit,
      coalesce(p.full_name,r.customer_name_snapshot,'Customer') as customer_name,v.name as vehicle_name,
      concat_ws(' ',v.name,p.full_name,p.phone,p.intended_vehicle_use,p.email,r.status) as search_text,
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
      coalesce((p.phone_verified or p.phone_verified_at is not null) and p.identity_verification_status='verified'
        and r.vehicle_id is not null and r.pickup_date is not null and r.return_date is not null
        and r.agreement_signed and coalesce(r.payment_status,'pending')='paid'
        and (coalesce(r.security_deposit,0)=0 or r.deposit_status in ('held','waived','released','transferred','release_pending','adjustment_refund_due'))
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
      'archive',terminal,'all',not terminal,'cars_out',cars_out,
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
    select * from matching order by created_at desc,id desc offset p_offset limit p_limit
  )
  select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(page)-array['search_text','matches'] order by created_at desc,id desc) from page),'[]'::jsonb),
    'total',(select count(*) from matching),'offset',p_offset,'limit',p_limit,
    'counts',(select jsonb_object_agg(key,n) from (select flags.key,count(*) filter(where flags.value='true'::jsonb) as n
      from classified cross join lateral jsonb_each(matches) flags group by flags.key) counts)) into result;
  return result;
end; $$;

create function public.admin_rental_detail(p_rental_id uuid)
returns jsonb language plpgsql stable security invoker set search_path=public as $$
declare r public.rentals%rowtype; result jsonb;
begin
  if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
    raise exception 'Rental access is required.' using errcode='42501'; end if;
  select * into r from public.rentals where id=p_rental_id;
  if not found then raise exception 'Rental not found.'; end if;
  select jsonb_build_object(
    'rental',to_jsonb(r)||jsonb_build_object('profiles',(select to_jsonb(p) from public.profiles p where p.id=r.user_id),
      'vehicles',(select to_jsonb(v) from public.vehicles v where v.id=r.vehicle_id)),
    'documents',coalesce((select jsonb_agg(d order by d.created_at desc,d.id desc) from public.rental_documents d where d.rental_id=r.id or
      (d.user_id=r.user_id and d.document_type='license')),'[]'),
    'reports',coalesce((select jsonb_agg(x order by x.created_at desc,x.id desc) from public.vehicle_reports x where x.rental_id=r.id),'[]'),
    'extensions',coalesce((select jsonb_agg(e order by e.created_at desc) from public.rental_extension_requests e where e.rental_id=r.id),'[]'),
    'exceptions',coalesce((select jsonb_agg(e) from public.rental_emergency_exceptions e where e.rental_id=r.id),'[]'),
    'steps',coalesce((select jsonb_agg(s) from public.rental_step_completions s where s.rental_id=r.id),'[]'),
    'deposits',coalesce((select jsonb_agg(d) from public.rental_deposit_allocations d where d.holder_rental_id=r.id),'[]'),
    'payments',coalesce((select jsonb_agg(p) from public.rental_payments p where p.rental_id=r.id),'[]'),
    'refunds',coalesce((select jsonb_agg(f) from public.rental_payment_refunds f where f.rental_id=r.id),'[]'),
    'charges',coalesce((select jsonb_agg(c) from public.rental_charge_items c where c.rental_id=r.id),'[]'),
    'externalActions',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('recorded_by_profile',
      (select jsonb_build_object('id',p.id,'full_name',p.full_name,'email',p.email) from public.profiles p where p.id=a.created_by)))
      from public.rental_external_payment_actions a where a.rental_id=r.id),'[]')
  ) into result;
  return result;
end; $$;

revoke all on function public.admin_rental_list(text,text,integer,integer,uuid),public.admin_rental_detail(uuid) from public,anon;
grant execute on function public.admin_rental_list(text,text,integer,integer,uuid),public.admin_rental_detail(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
