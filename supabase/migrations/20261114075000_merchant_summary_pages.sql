begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
do $$ begin if (select md5(prosrc) from pg_proc where oid='public.admin_merchant_workspace(text,jsonb)'::regprocedure)<>'010f985ed3199948b8530dc952c0fd67' then raise exception 'Merchant workspace baseline changed'; end if; end $$;
CREATE OR REPLACE FUNCTION public.admin_merchant_workspace(p_action text DEFAULT 'list'::text, p_data jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_id uuid; v_email text;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='admin' and staff_role in ('owner','operations_manager')) then
    raise exception 'Merchant management requires an owner or operations manager.' using errcode='42501';
  end if;

  if coalesce((p_data->>'offset')::integer,0)<0 or coalesce((p_data->>'offset')::integer,0)>1000000 then raise exception 'Invalid merchant page.'; end if;
  if p_action='detail' then
    return (select to_jsonb(d) from merchant_booking_details d where d.rental_id=(p_data->>'rental_id')::uuid);
  end if;
  if p_action in ('invite','membership') then
    raise exception 'Merchant accounts are provisioned only by the owner through the trusted backend. Portal account creation and access changes are disabled.' using errcode='42501';
  elsif p_action='bookings' then
    update merchants set bookings_enabled=(p_data->>'enabled')::boolean where id=(p_data->>'id')::uuid;
  elsif p_action='revoke_verification' then
    v_id:=(p_data->>'rental_id')::uuid;
    if length(trim(coalesce(p_data->>'reason','')))<5 then raise exception 'Enter a reason.'; end if;
    perform 1 from rentals where id=v_id and status not in ('active','rented','overdue','return_initiated','completed') for update;
    if not found then raise exception 'Use the active rental incident workflow after pickup.'; end if;
    update merchant_booking_details set revoked_at=now(),revoked_reason=p_data->>'reason' where rental_id=v_id;
    update rentals set status='documents_needed' where id=v_id and status in ('approved','ready_for_pickup','document_review');
  elsif p_action<>'list' then raise exception 'Unsupported merchant action.';
  end if;
  if p_action<>'list' then
    insert into admin_audit_logs(actor_user_id,action,entity_type,entity_id,metadata)
    values(auth.uid(),'merchant.'||p_action,'merchant',coalesce(p_data->>'merchant_id',p_data->>'id',p_data->>'rental_id',''),
      p_data-'email');
  end if;
  return jsonb_build_object(
    'merchants',(select coalesce(jsonb_agg(to_jsonb(m)),'[]') from merchants m),
    'memberships',(select coalesce(jsonb_agg(to_jsonb(mm)),'[]') from merchant_memberships mm),
    'bookings',(select coalesce(jsonb_agg(x order by x.created_at desc),'[]') from (
      select r.id,r.merchant_id,r.status,r.payment_status,r.created_at,r.merchant_documents_due_at,
        r.pickup_date,r.return_date,v.name as vehicle_name,d.rental_id,d.full_name,d.revoked_at,
        rentmect_rental_requirement_complete(r.id,'license') as license_approved,
        rentmect_rental_requirement_complete(r.id,'insurance') as insurance_approved,
        (select status from email_outbox where rental_id=r.id and email_type='merchant_documents' order by created_at desc limit 1) as delivery_status
      from rentals r join merchant_booking_details d on d.rental_id=r.id join vehicles v on v.id=r.vehicle_id
      where coalesce(p_data->>'filter','all')='all' or (r.payment_status='paid' and r.status not in ('ready_for_pickup','active','rented','overdue','return_initiated','completed','cancelled'))
      order by r.created_at desc,r.id desc offset coalesce((p_data->>'offset')::integer,0) limit 51
    ) x));
end; $$;
commit;
