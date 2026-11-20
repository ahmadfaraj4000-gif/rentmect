begin;

CREATE OR REPLACE FUNCTION public.admin_flexible_payment_revenue()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
begin
 if auth.uid() is null or not is_admin() or not coalesce(rentmect_has_permission('reports.financial'),false)
 or not coalesce(rentmect_has_permission('tab.payments'),false)
 or not exists(select 1 from profiles where id=auth.uid() and lower(email) in ('anconamgt@aol.com', 'jennifer@rentmect.com')) then raise exception 'Revenue report access denied.'; end if;
 return jsonb_build_object('allocatedReceipts',coalesce((select jsonb_agg(jsonb_build_object(
  'id',id,'rental_id',rental_id,'funding_kind',funding_kind,'amount_cents',amount_cents,'credit_amount_cents',credit_amount_cents,
  'status',status,'received_date',received_date,'posted_at',posted_at,'refunded_at',refunded_at)) from external_payment_receipts where allocation_version=2 and status in ('posted','refunded')),'[]'),
  'allocatedEntries',coalesce((select jsonb_agg(jsonb_build_object('receipt_id',a.receipt_id,'charge_id',a.charge_id,'amount_cents',a.amount_cents,
  'charge_type',a.snapshot->>'charge_type','total_amount',a.snapshot->'total_amount','tax_amount',a.snapshot->'tax_amount'))
  from external_payment_allocations a join external_payment_receipts r on r.id=a.receipt_id where r.allocation_version=2 and r.status in ('posted','refunded')),'[]'));
end $function$;

CREATE OR REPLACE FUNCTION public.admin_payment_revenue_snapshot_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
 SET statement_timeout TO '8s'
AS $function$
declare result jsonb;
begin
  if auth.uid() is null or not coalesce(public.is_admin(),false)
    or not coalesce(public.rentmect_has_permission('tab.payments'),false)
    or not coalesce(public.rentmect_has_permission('reports.financial'),false)
    or not exists(select 1 from public.profiles where id=auth.uid() and lower(email) in ('anconamgt@aol.com', 'jennifer@rentmect.com')) then
    raise exception 'Revenue report access denied.' using errcode='42501';
  end if;
  select jsonb_build_object(
    'rentals',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_total,service_fee_total,tax_amount,security_deposit,paid_at,payment_amount_cents,deposit_held_amount,deposit_released_amount,deposit_status,stripe_payment_intent_id,stripe_checkout_session_id,created_at,payment_received_date from public.rentals order by id limit 500001) r),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,status,payment_type,total_amount,rental_amount,tax_amount,deposit_amount,paid_at,refunded_amount,deposit_refunded_at,stripe_payment_intent_id,stripe_checkout_session_id,created_at,payment_received_date from public.rental_payments order by id limit 500001) r),'[]'::jsonb),
    'charges',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,charge_type,included_in_initial_payment,status,payment_provider,total_amount,tax_amount,payment_amount_cents,paid_at,stripe_payment_intent_id,stripe_checkout_session_id,amount,created_at,payment_received_date,external_refunded_amount,external_refunded_at from public.rental_charge_items order by id limit 500001) r),'[]'::jsonb),
    'extensions',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,replacement_rental_id,status,payment_status,request_kind,extension_rental_amount,extension_tax_amount,extension_total_amount,extension_deposit_amount,payment_amount_cents,paid_at,stripe_payment_intent_id,stripe_checkout_session_id,created_at,payment_received_date from public.rental_extension_requests order by id limit 500001) r),'[]'::jsonb),
    'refunds',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,status,source_type,stripe_refund_id,stripe_payment_intent_id,extension_request_id,amount,created_at from public.rental_payment_refunds order by id limit 500001) r),'[]'::jsonb),
    'externalActions',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,action_type,amount,deposit_amount_returned,payment_charge_id,created_at from public.rental_external_payment_actions order by id limit 500001) r),'[]'::jsonb),
    'applications',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,rental_id,allocation_id,charge_id,amount,created_at from public.rental_deposit_charge_applications order by id limit 500001) r),'[]'::jsonb),
    'allocations',coalesce((select jsonb_agg(to_jsonb(r) order by r.id) from (select id,source_rental_id,holder_rental_id,source_kind,amount_held,amount_applied,stripe_payment_intent_id from public.rental_deposit_allocations order by id limit 500001) r),'[]'::jsonb)
  ) into result;
  if exists(select 1 from jsonb_each(result) entry where jsonb_array_length(entry.value)>500000) then
    raise exception 'Revenue history exceeded the reporting limit.';
  end if;
  return result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_employee_permission(p_permission_key text, p_enabled boolean)
 RETURNS employee_permissions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor public.profiles%rowtype;
  v_permission public.employee_permissions%rowtype;
  v_previous boolean;
begin
  select * into v_actor from public.profiles where id = auth.uid();
  if not found or v_actor.role <> 'admin' or not (
    v_actor.staff_role = 'owner' or lower(coalesce(v_actor.email, '')) in ('anconamgt@aol.com', 'jennifer@rentmect.com')
  ) then
    raise exception 'Only an authorized manager can change Employee permissions.';
  end if;

  select enabled into v_previous from public.employee_permissions
  where permission_key = p_permission_key for update;
  if not found then raise exception 'Unknown Employee permission.'; end if;

  update public.employee_permissions
  set enabled = p_enabled, updated_by = auth.uid(), updated_at = now()
  where permission_key = p_permission_key
  returning * into v_permission;

  perform public.record_admin_audit_event(
    'employee_permission.updated', 'employee_permission', p_permission_key,
    jsonb_build_object('previous_enabled', v_previous, 'enabled', p_enabled, 'applies_to_role', 'employee')
  );
  return v_permission;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_staff_permission_override(p_user_id uuid, p_permission_key text, p_enabled boolean, p_reason text DEFAULT NULL::text)
 RETURNS staff_permission_overrides
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_actor public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_override public.staff_permission_overrides%rowtype;
begin
  select * into v_actor from public.profiles where id = auth.uid();
  if not found or v_actor.role <> 'admin' or not (
    v_actor.staff_role in ('owner', 'operations_manager')
    or lower(coalesce(v_actor.email, '')) in ('anconamgt@aol.com', 'jennifer@rentmect.com')
  ) then
    raise exception 'Only an authorized manager can change staff permission overrides.';
  end if;

  select * into v_target from public.profiles where id = p_user_id;
  if not found or v_target.role <> 'admin' or v_target.staff_role <> 'employee' then
    raise exception 'Permission overrides can only be applied to Employee accounts.';
  end if;
  if not exists (select 1 from public.employee_permissions where permission_key = p_permission_key) then
    raise exception 'Unknown Employee permission.';
  end if;

  insert into public.staff_permission_overrides (
    user_id, permission_key, enabled, reason, updated_by, updated_at
  ) values (
    p_user_id, p_permission_key, p_enabled, nullif(trim(coalesce(p_reason, '')), ''), auth.uid(), now()
  )
  on conflict (user_id, permission_key) do update set
    enabled = excluded.enabled,
    reason = excluded.reason,
    updated_by = excluded.updated_by,
    updated_at = excluded.updated_at
  returning * into v_override;

  perform public.record_admin_audit_event(
    'staff_permission_override.updated',
    'profile',
    p_user_id::text,
    jsonb_build_object(
      'permission_key', p_permission_key,
      'enabled', p_enabled,
      'reason', nullif(trim(coalesce(p_reason, '')), ''),
      'target_email', v_target.email
    )
  );
  return v_override;
end;
$function$;

CREATE OR REPLACE FUNCTION public.can_view_accountant_ledger()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select coalesce(public.is_admin(), false)
    and exists (select 1 from public.profiles where id=auth.uid() and lower(email) in ('anconamgt@aol.com', 'jennifer@rentmect.com'))
$function$;

CREATE OR REPLACE FUNCTION public.enforce_admin_email_allowlist()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_auth_email text;
  v_actor_role text;
  v_actor_email text;
begin
  if lower(coalesce(new.role, 'client')) <> 'admin' then return new; end if;

  select lower(trim(auth_user.email)) into v_auth_email
  from auth.users auth_user where auth_user.id = new.id;
  if v_auth_email is null or v_auth_email <> lower(trim(coalesce(new.email, v_auth_email))) then
    raise exception 'The staff profile must match its Auth login email.';
  end if;

  if new.staff_role not in ('owner', 'operations_manager', 'employee') then
    raise exception 'Choose a valid staff role before granting admin portal access.';
  end if;

  -- Service-role provisioning has no end-user auth.uid(). Interactive changes
  -- are limited to owners and the named Operations Manager.
  if auth.uid() is null then return new; end if;
  select profile.staff_role, lower(coalesce(profile.email, ''))
    into v_actor_role, v_actor_email
  from public.profiles profile where profile.id = auth.uid();

  if v_actor_role <> 'owner' and v_actor_email not in ('anconamgt@aol.com', 'jennifer@rentmect.com') then
    raise exception 'Only an owner or authorized Operations Manager can grant staff access.';
  end if;
  if new.staff_role = 'owner' and v_actor_role <> 'owner' then
    raise exception 'Only an owner can grant owner access.';
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_admin_staff_context()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'staff_role', profile.staff_role,
    'can_manage_employee_permissions', profile.staff_role = 'owner'
      or lower(coalesce(profile.email, '')) in ('anconamgt@aol.com', 'jennifer@rentmect.com'),
    'permissions', coalesce((
      select jsonb_object_agg(
        permission.permission_key,
        case
          when permission.permission_key = 'dashboard.financial_summary' then
            lower(coalesce(profile.email, '')) in ('anconamgt@aol.com', 'jennifer@rentmect.com')
          when profile.staff_role in ('owner', 'operations_manager') then true
          else coalesce(override.enabled, permission.enabled)
        end
      )
      from public.employee_permissions permission
      left join public.staff_permission_overrides override
        on override.user_id = profile.id
       and override.permission_key = permission.permission_key
    ), '{}'::jsonb)
  )
  from public.profiles profile
  where profile.id = auth.uid() and profile.role = 'admin';
$function$;

CREATE OR REPLACE FUNCTION public.rentmect_has_permission(p_permission_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case
    when p_permission_key = 'dashboard.financial_summary' then
      lower(coalesce(profile.email, '')) in ('anconamgt@aol.com', 'jennifer@rentmect.com')
    when profile.staff_role in ('owner', 'operations_manager') then true
    when profile.staff_role = 'employee' then coalesce(
      (
        select override.enabled
        from public.staff_permission_overrides override
        where override.user_id = profile.id
          and override.permission_key = p_permission_key
      ),
      (
        select permission.enabled
        from public.employee_permissions permission
        where permission.permission_key = p_permission_key
      ),
      false
    )
    else false
  end
  from public.profiles profile
  where profile.id = auth.uid() and profile.role = 'admin';
$function$;

commit;
