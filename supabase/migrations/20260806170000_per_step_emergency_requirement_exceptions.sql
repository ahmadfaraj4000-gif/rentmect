begin;

-- Rejected replacements must reset the requirement. Only the newest document
-- controls whether license or insurance is complete.
create or replace function public.rentmect_rental_requirement_complete(
  p_rental_id uuid,
  p_scope text
) returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
begin
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then return false; end if;

  case p_scope
    when 'phone' then
      return exists (
        select 1 from public.profiles
        where id = v_rental.user_id and coalesce(phone_verified, false)
      );
    when 'identity' then
      return public.rentmect_identity_is_verified(v_rental.user_id);
    when 'agreement' then
      return coalesce(v_rental.agreement_signed, false);
    when 'payment' then
      return lower(coalesce(v_rental.payment_status, '')) = 'paid';
    when 'license' then
      return coalesce((
        select lower(coalesce(document.status, '')) = 'approved'
        from public.rental_documents document
        where document.user_id = v_rental.user_id
          and document.document_type = 'license'
        order by document.created_at desc nulls last, document.id desc
        limit 1
      ), false);
    when 'insurance' then
      return coalesce((
        select lower(coalesce(document.status, '')) = 'approved'
        from public.rental_documents document
        where document.rental_id = v_rental.id
          and document.user_id = v_rental.user_id
          and document.document_type = 'insurance'
        order by document.created_at desc nulls last, document.id desc
        limit 1
      ), false);
    else
      return false;
  end case;
end;
$$;

-- Expired rows previously kept the partial unique index occupied even though
-- they no longer covered a requirement.
update public.rental_emergency_exceptions
set status = 'revoked',
    resolved_at = coalesce(resolved_at, now()),
    resolution_note = coalesce(resolution_note, 'Expired before another emergency exception was recorded.'),
    updated_at = now()
where status = 'active'
  and expires_at <= now();

create or replace function public.admin_add_rental_emergency_exception_scope(
  p_rental_id uuid,
  p_scope text,
  p_reason text,
  p_evidence_note text,
  p_expires_at timestamptz,
  p_confirmation text
) returns public.rental_emergency_exceptions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_admin public.profiles%rowtype;
  v_rental public.rentals%rowtype;
  v_exception public.rental_emergency_exceptions%rowtype;
  v_existing public.rental_emergency_exceptions%rowtype;
  v_scopes text[];
  v_resolved text[];
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;

  select * into v_admin from public.profiles where id = v_admin_id;
  if not coalesce(v_admin.emergency_override_authorized, false) then
    raise exception 'This staff account is not authorized for emergency release exceptions.';
  end if;
  if trim(coalesce(p_confirmation, '')) <> 'BYPASS STEP' then
    raise exception 'Type BYPASS STEP to confirm.';
  end if;
  if p_scope is null or not (p_scope = any(array['phone','identity','license','insurance','agreement','payment']::text[])) then
    raise exception 'Choose one valid procedure step.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 20 then
    raise exception 'Enter a specific emergency reason of at least 20 characters.';
  end if;
  if p_expires_at is null
     or p_expires_at <= now() + interval '15 minutes'
     or p_expires_at > now() + interval '24 hours' then
    raise exception 'Exception expiry must be between 15 minutes and 24 hours from now.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;

  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) not in
    ('pending','documents_needed','document_review','approved','ready_for_pickup') then
    raise exception 'This rental is not eligible for a requirement exception.';
  end if;
  if public.rentmect_rental_requirement_complete(v_rental.id, p_scope) then
    raise exception '% is already complete and cannot be bypassed.', initcap(p_scope);
  end if;

  update public.rental_emergency_exceptions
  set status = 'revoked',
      resolved_at = coalesce(resolved_at, now()),
      resolution_note = coalesce(resolution_note, 'Expired before another emergency exception was recorded.'),
      updated_at = now()
  where rental_id = v_rental.id
    and status = 'active'
    and expires_at <= now();

  select * into v_existing
  from public.rental_emergency_exceptions
  where rental_id = v_rental.id
    and status = 'active'
    and expires_at > now()
  for update;

  if found then
    if p_scope = any(v_existing.exception_scopes)
       and not (p_scope = any(v_existing.resolved_scopes)) then
      raise exception '% already has an active emergency exception.', initcap(p_scope);
    end if;

    select array_agg(distinct scope_name order by scope_name)
    into v_scopes
    from unnest(v_existing.exception_scopes || array[p_scope]) as listed_scope(scope_name);
    v_resolved := array_remove(v_existing.resolved_scopes, p_scope);

    update public.rental_emergency_exceptions
    set exception_scopes = v_scopes,
        resolved_scopes = v_resolved,
        reason = v_existing.reason || E'\n[' || initcap(p_scope) || '] ' || trim(p_reason),
        evidence_note = concat_ws(E'\n', v_existing.evidence_note, nullif(trim(coalesce(p_evidence_note, '')), '')),
        expires_at = greatest(v_existing.expires_at, p_expires_at),
        updated_at = now()
    where id = v_existing.id
    returning * into v_exception;
  else
    insert into public.rental_emergency_exceptions (
      rental_id, user_id, requested_by, exception_scopes, reason,
      evidence_note, expires_at
    ) values (
      v_rental.id, v_rental.user_id, v_admin_id, array[p_scope],
      '[' || initcap(p_scope) || '] ' || trim(p_reason),
      nullif(trim(coalesce(p_evidence_note, '')), ''), p_expires_at
    ) returning * into v_exception;
  end if;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id,
    'emergency_requirement_exception_added',
    jsonb_build_object(
      'exception_id', v_exception.id,
      'scope', p_scope,
      'reason', trim(p_reason),
      'evidence_note', nullif(trim(coalesce(p_evidence_note, '')), ''),
      'expires_at', p_expires_at,
      'rental_released', false
    )
  );

  insert into public.admin_audit_logs (
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id, metadata
  ) values (
    v_admin_id, v_admin.email, v_admin.role,
    'rental.emergency_requirement_exception_added', 'rental', v_rental.id::text,
    jsonb_build_object(
      'exception_id', v_exception.id,
      'scope', p_scope,
      'expires_at', p_expires_at
    )
  );

  insert into public.admin_notification_events (
    event_type, source_id, rental_id, dedupe_key
  ) values (
    'emergency_exception_created', v_exception.id, v_rental.id,
    'emergency_exception_scope:' || v_exception.id::text || ':' || p_scope
  ) on conflict (dedupe_key) do nothing;

  return v_exception;
end;
$$;

revoke all on function public.admin_add_rental_emergency_exception_scope(
  uuid, text, text, text, timestamptz, text
) from public;
grant execute on function public.admin_add_rental_emergency_exception_scope(
  uuid, text, text, text, timestamptz, text
) to authenticated;

-- Release is allowed only when every requirement is either genuinely complete
-- or covered by a still-active, individually audited exception. Vehicle safety
-- and calendar conflicts are never bypassable.
create or replace function public.admin_mark_rental_active(
  p_rental_id uuid,
  p_starting_mileage integer,
  p_override_missing_requirements boolean default false,
  p_missing_requirements text[] default '{}'::text[]
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_missing text[];
  v_exception_scopes text[];
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if p_override_missing_requirements then
    raise exception 'Use an audited per-step emergency exception instead of a blanket override.';
  end if;
  if p_starting_mileage is null or p_starting_mileage < 0 then
    raise exception 'Starting mileage is required.';
  end if;

  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status, '')) not in
    ('pending','documents_needed','document_review','approved','ready_for_pickup') then
    raise exception 'Only pending or reviewed rentals can be marked active.';
  end if;

  select * into v_vehicle
  from public.vehicles
  where id = v_rental.vehicle_id
  for update;
  if not found then raise exception 'Vehicle not found.'; end if;
  if lower(coalesce(v_vehicle.status, 'available')) in
    ('maintenance','unavailable','inactive','rented') then
    raise exception 'Unsafe, unavailable, inactive, or already-rented vehicles cannot be released.';
  end if;
  if v_vehicle.current_mileage is not null
     and p_starting_mileage < v_vehicle.current_mileage then
    raise exception 'Starting mileage cannot be below the vehicle current mileage.';
  end if;

  if exists (
    select 1 from public.rentals rental
    where rental.id <> v_rental.id
      and rental.vehicle_id = v_rental.vehicle_id
      and lower(coalesce(rental.status, '')) <> 'cancelled'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(rental.pickup_date, rental.pickup_time),
        public.rentmect_rental_timestamp(rental.return_date, rental.return_time) + interval '3 hours'
      )
  ) or exists (
    select 1 from public.vehicle_availability_blocks availability_block
    where availability_block.vehicle_id = v_rental.vehicle_id
      and coalesce(availability_block.active, true)
      and lower(coalesce(availability_block.block_type, 'unavailable')) <> 'available'
      and public.rentmect_periods_overlap(
        public.rentmect_rental_timestamp(v_rental.pickup_date, v_rental.pickup_time),
        public.rentmect_rental_timestamp(v_rental.return_date, v_rental.return_time) + interval '3 hours',
        public.rentmect_rental_timestamp(availability_block.start_date, availability_block.start_time),
        public.rentmect_rental_timestamp(availability_block.end_date, availability_block.end_time)
      )
  ) then
    raise exception 'Vehicle schedule conflicts and calendar blocks cannot be overridden.';
  end if;

  select coalesce(array_agg(scope order by scope), '{}') into v_missing
  from unnest(array['phone','identity','license','insurance','agreement','payment']::text[]) scope
  where not public.rentmect_rental_requirement_complete(v_rental.id, scope)
    and not public.rentmect_active_exception_covers(v_rental.id, scope);

  if cardinality(v_missing) > 0 then
    raise exception 'Complete or individually bypass these steps before release: %',
      array_to_string(v_missing, ', ');
  end if;

  select coalesce(array_agg(scope order by scope), '{}') into v_exception_scopes
  from unnest(array['phone','identity','license','insurance','agreement','payment']::text[]) scope
  where public.rentmect_active_exception_covers(v_rental.id, scope);

  update public.rentals
  set status = 'active',
      starting_mileage = p_starting_mileage,
      ending_mileage = null
  where id = v_rental.id
  returning * into v_rental;

  update public.vehicles
  set status = 'rented',
      current_mileage = p_starting_mileage
  where id = v_rental.vehicle_id;

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_rental_marked_active',
    jsonb_build_object(
      'starting_mileage', p_starting_mileage,
      'emergency_exception_scopes', v_exception_scopes,
      'all_requirements_complete_or_individually_bypassed', true
    )
  );

  return v_rental;
end;
$$;

revoke all on function public.admin_mark_rental_active(
  uuid, integer, boolean, text[]
) from public;
grant execute on function public.admin_mark_rental_active(
  uuid, integer, boolean, text[]
) to authenticated;

comment on function public.admin_add_rental_emergency_exception_scope(
  uuid, text, text, text, timestamptz, text
) is 'Adds one audited, expiring emergency exception without releasing the vehicle or bypassing any other requirement.';

-- Rejection is a customer action item, not only an Admin status change. Queue a
-- transactional email and return any not-yet-active rental to Documents Needed.
insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader,
  html_body, text_body, enabled
) values (
  'rental_document_rejected',
  'Rental Document Rejected',
  'automated',
  'rental.document_rejected',
  'Action required: replace your {{document_label}}',
  'A rental document needs to be replaced before pickup.',
  '<h1>Please replace your {{document_label}}.</h1><p>Hi {{customer_first_name}},</p><p>We could not approve the {{document_label}} uploaded for <strong>{{vehicle_name}}</strong>.</p><p>Your document step has reopened. Upload a clear, valid replacement so Rent Me CT can review it before pickup.</p><p><a href="{{manage_booking_url}}">Upload a replacement document</a></p><p>If you believe this was rejected by mistake, contact Rent Me CT.</p>',
  'Hi {{customer_first_name}}, we could not approve the {{document_label}} uploaded for {{vehicle_name}}. Your document step has reopened. Upload a valid replacement here: {{manage_booking_url}}',
  true
) on conflict (template_key) do update set
  name = excluded.name,
  category = excluded.category,
  trigger_key = excluded.trigger_key,
  subject = excluded.subject,
  preheader = excluded.preheader,
  html_body = excluded.html_body,
  text_body = excluded.text_body,
  enabled = true,
  version = public.email_templates.version + 1,
  updated_at = now();

create or replace function public.handle_rental_document_rejection()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template public.email_templates%rowtype;
  v_profile public.profiles%rowtype;
  v_rental public.rentals%rowtype;
  v_vehicle public.vehicles%rowtype;
  v_document_label text;
begin
  if lower(coalesce(new.status, '')) <> 'rejected'
     or lower(coalesce(old.status, '')) = 'rejected' then
    return new;
  end if;

  if new.document_type = 'license' then
    update public.rentals
    set status = 'documents_needed', updated_at = now()
    where user_id = new.user_id
      and lower(coalesce(status, '')) in ('document_review','approved','ready_for_pickup');
  elsif new.rental_id is not null then
    update public.rentals
    set status = 'documents_needed', updated_at = now()
    where id = new.rental_id
      and lower(coalesce(status, '')) in ('document_review','approved','ready_for_pickup');
  end if;

  select * into v_template
  from public.email_templates
  where template_key = 'rental_document_rejected'
    and category = 'automated'
    and enabled
  limit 1;
  if not found then return new; end if;

  select * into v_profile from public.profiles where id = new.user_id;
  if nullif(trim(coalesce(v_profile.email, '')), '') is null then return new; end if;

  if new.rental_id is not null then
    select * into v_rental from public.rentals where id = new.rental_id;
    if found then select * into v_vehicle from public.vehicles where id = v_rental.vehicle_id; end if;
  end if;

  v_document_label := case new.document_type
    when 'insurance' then 'insurance declaration page'
    when 'license' then 'driver license'
    else replace(coalesce(new.document_type, 'rental document'), '_', ' ')
  end;

  insert into public.email_outbox (
    event_key, email_type, template_id, rental_id, user_id,
    recipient_email, recipient_name, payload
  ) values (
    'rental_document_rejected:' || new.id::text || ':' || md5(coalesce(new.file_path, '')),
    'rental_document_rejected', v_template.id, new.rental_id, new.user_id,
    lower(trim(v_profile.email)), v_profile.full_name,
    jsonb_build_object(
      'customer_name', coalesce(v_profile.full_name, 'Customer'),
      'customer_first_name', split_part(coalesce(v_profile.full_name, 'Customer'), ' ', 1),
      'document_label', v_document_label,
      'vehicle_name', coalesce(v_vehicle.name, 'your rental vehicle'),
      'manage_booking_url', 'https://login.rentmect.com'
    )
  ) on conflict (event_key) do nothing;

  if new.rental_id is not null then
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    ) values (
      new.rental_id, new.user_id, auth.uid(), 'rental_document_rejected',
      jsonb_build_object(
        'document_id', new.id,
        'document_type', new.document_type,
        'customer_email_queued', true,
        'replacement_required', true
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists rental_documents_handle_rejection on public.rental_documents;
create trigger rental_documents_handle_rejection
after update of status on public.rental_documents
for each row execute function public.handle_rental_document_rejection();

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'rental_emergency_exceptions'
  ) then
    alter publication supabase_realtime add table public.rental_emergency_exceptions;
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
