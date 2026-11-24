begin;
-- Extend the installed event constraint without dropping any previously supported event.
do $$ declare previous text; begin
  select pg_get_expr(conbin,conrelid) into strict previous from pg_constraint
  where conrelid='public.admin_notification_events'::regclass and conname='admin_notification_events_event_type_check';
  alter table public.admin_notification_events drop constraint admin_notification_events_event_type_check;
  execute format('alter table public.admin_notification_events add constraint admin_notification_events_event_type_check check ((%s) or event_type=%L)',previous,'online_customer_steps_complete');
end $$;

-- Sweep committed state so webhook, signature and separate insurance uploads may arrive in any order.
create function public.queue_online_rental_preparation() returns void
language sql security definer set search_path=public as $$
  insert into admin_notification_events(event_type,source_id,rental_id,dedupe_key)
  select 'online_customer_steps_complete',r.id,r.id,'online_prep:'||r.id
  from rentals r join profiles p on p.id=r.user_id
  where r.booking_source in ('customer_portal','website_hold') and r.status in ('pending','documents_needed','document_review','approved','ready_for_pickup')
    and r.payment_status='paid' and r.agreement_signed and r.vehicle_id is not null
    and r.pickup_date is not null and r.return_date is not null
    and not exists(select from admin_notification_events n where n.dedupe_key='online_prep:'||r.id)
    and (p.phone_verified or (r.merchant_id is null and p.phone_verified_at is not null))
    and case when r.merchant_id is null then p.identity_verification_status='verified'
      else coalesce((get_customer_merchant_verification(r.id)->>'verified')::boolean,false) end
    and (select d.status from rental_documents d where d.user_id=r.user_id and d.document_type='license'
      order by d.created_at desc,d.id desc limit 1) in ('pending_review','approved')
    and (select bool_and(d.status in ('pending_review','approved')) and
      (bool_or(coalesce(d.insurance_coverage_type,'combined')='combined') or
        (bool_or(d.insurance_coverage_type='liability') and bool_or(d.insurance_coverage_type='collision')))
      from rental_documents d where d.rental_id=r.id and d.document_type='insurance' and d.extension_request_id is null
      and coalesce(d.insurance_packet_id,d.id)=(select coalesce(x.insurance_packet_id,x.id) from rental_documents x
        where x.rental_id=r.id and x.document_type='insurance' and x.extension_request_id is null order by x.created_at desc,x.id desc limit 1))
  on conflict(dedupe_key) do nothing;
$$;
revoke all on function public.queue_online_rental_preparation() from public,anon,authenticated;
grant execute on function public.queue_online_rental_preparation() to service_role;
-- Establish a baseline without paging staff about pre-existing completed checklists.
select public.queue_online_rental_preparation();
update public.admin_notification_events set status='sent',sent_at=now(),provider_request_id='preexisting-checklist'
where event_type='online_customer_steps_complete' and status='pending' and created_at=now();
select cron.schedule('rentmect-online-preparation','* * * * *','select public.queue_online_rental_preparation()');
commit;
