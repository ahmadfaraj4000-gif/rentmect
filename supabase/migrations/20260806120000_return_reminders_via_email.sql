begin;

-- Return reminders are transactional messages. They do not require marketing
-- consent, but they do require a usable email address on the customer profile.
insert into public.email_templates (
  template_key,
  name,
  category,
  trigger_key,
  subject,
  preheader,
  html_body,
  text_body,
  enabled
) values
  (
    'return_due_previous_morning_email',
    'Return Reminder — Day Before',
    'automated',
    'rental.return_due_previous_morning',
    'Return reminder: {{vehicle_name}} is due {{return_date}}',
    'Your Rent Me CT rental return is coming up.',
    '<h1>Your rental return is tomorrow.</h1><p>Hi {{customer_first_name}},</p><p>This is a reminder that <strong>{{vehicle_name}}</strong> is due back on <strong>{{return_date}} at {{return_time}} ET</strong>.</p><p>If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review.</p><p><a href="{{manage_booking_url}}">Manage your rental</a> or call us at {{business_phone}} if you need help.</p>',
    'Hi {{customer_first_name}}, this is a reminder that {{vehicle_name}} is due back on {{return_date}} at {{return_time}} ET. If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review. Manage your rental: {{manage_booking_url}}. Questions: {{business_phone}}.',
    true
  ),
  (
    'return_due_3h_email',
    'Return Reminder — Three Hours Before',
    'automated',
    'rental.return_due_3h',
    'Your {{vehicle_name}} return is due in about 3 hours',
    'Your scheduled Rent Me CT return time is approaching.',
    '<h1>Your rental return is due soon.</h1><p>Hi {{customer_first_name}},</p><p><strong>{{vehicle_name}}</strong> is due back today, <strong>{{return_date}} at {{return_time}} ET</strong>.</p><p>If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review.</p><p><a href="{{manage_booking_url}}">Manage your rental</a> or call us at {{business_phone}} if you need help.</p>',
    'Hi {{customer_first_name}}, {{vehicle_name}} is due back today, {{return_date}} at {{return_time}} ET. If the vehicle is not returned within three hours of the scheduled return time, one additional full rental day plus a $25 late-return fee will be prepared for admin review. Manage your rental: {{manage_booking_url}}. Questions: {{business_phone}}.',
    true
  ),
  (
    'return_overdue_3h_email',
    'Overdue Return Reminder — Three Hours After',
    'automated',
    'rental.return_overdue_3h',
    'Action needed: your {{vehicle_name}} return is overdue',
    'Please contact Rent Me CT about your overdue rental return.',
    '<h1>Your rental return is overdue.</h1><p>Hi {{customer_first_name}},</p><p><strong>{{vehicle_name}}</strong> was due back on <strong>{{return_date}} at {{return_time}} ET</strong> and is now more than three hours overdue.</p><p>One additional full rental day plus a $25 late-return fee will be prepared for admin review. Additional recovery charges may apply under your rental agreement.</p><p>Please <a href="{{manage_booking_url}}">open your rental</a> or call us now at {{business_phone}}.</p>',
    'Hi {{customer_first_name}}, {{vehicle_name}} was due back on {{return_date}} at {{return_time}} ET and is now more than three hours overdue. One additional full rental day plus a $25 late-return fee will be prepared for admin review. Additional recovery charges may apply under your rental agreement. Open your rental: {{manage_booking_url}}. Call us now: {{business_phone}}.',
    true
  )
on conflict (template_key) do update
set
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

-- These helpers preserve the live 8:00 AM-9:00 PM America/New_York quiet
-- hours while making the rule independent of the delivery channel.
create or replace function public.rentmect_pre_due_customer_message_time(
  p_target_at timestamptz,
  p_due_at timestamptz
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  v_target_local timestamp without time zone :=
    p_target_at at time zone 'America/New_York';
  v_due_local timestamp without time zone :=
    p_due_at at time zone 'America/New_York';
  v_send_local timestamp without time zone;
begin
  if v_target_local::time < time '08:00' then
    v_send_local := v_target_local::date + time '08:00';
    if v_send_local >= v_due_local then
      v_send_local := (v_target_local::date - 1) + time '21:00';
    end if;
  elsif v_target_local::time > time '21:00' then
    v_send_local := v_target_local::date + time '21:00';
  else
    v_send_local := v_target_local;
  end if;

  return v_send_local at time zone 'America/New_York';
end;
$$;

create or replace function public.rentmect_next_visible_customer_message_time(
  p_target_at timestamptz
)
returns timestamptz
language plpgsql
stable
set search_path = public
as $$
declare
  v_target_local timestamp without time zone :=
    p_target_at at time zone 'America/New_York';
  v_send_local timestamp without time zone;
begin
  if v_target_local::time < time '08:00' then
    v_send_local := v_target_local::date + time '08:00';
  elsif v_target_local::time > time '21:00' then
    v_send_local := (v_target_local::date + 1) + time '08:00';
  else
    v_send_local := v_target_local;
  end if;

  return v_send_local at time zone 'America/New_York';
end;
$$;

create or replace function public.queue_due_rental_return_email_reminders(
  p_send_after timestamptz default now() - interval '15 minutes',
  p_send_before timestamptz default now() + interval '1 minute',
  p_limit integer default 100
) returns table (
  outbox_id uuid,
  reminder_type text,
  rental_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required.';
  end if;

  -- Do not retry a reminder after the return schedule or rental eligibility
  -- changes. A newly eligible schedule receives a distinct idempotency key.
  update public.email_outbox as outbox
  set
    status = 'cancelled',
    last_error = 'Return reminder cancelled because the rental schedule or status changed.',
    updated_at = now()
  from public.rentals as rental
  left join public.profiles as profile
    on profile.id = rental.user_id
  where outbox.rental_id = rental.id
    and outbox.email_type in (
      'return_due_previous_morning_email',
      'return_due_3h_email',
      'return_overdue_3h_email'
    )
    and outbox.status in ('pending', 'failed')
    and (
      lower(coalesce(rental.payment_status, '')) <> 'paid'
      or coalesce(lower(rental.status), '') in ('completed', 'cancelled', 'return_initiated')
      or (
        outbox.email_type = 'return_overdue_3h_email'
        and coalesce(lower(rental.status), '') not in ('active', 'rented', 'overdue')
      )
      or rental.return_date is null
      or nullif(trim(coalesce(profile.email, '')), '') is null
      or trim(profile.email) !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      or outbox.recipient_email is distinct from lower(trim(profile.email))
      or outbox.payload ->> 'return_due_key' is distinct from
        extract(epoch from (
          public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
            at time zone 'America/New_York'
        ))::bigint::text
    );

  return query
  with rentals_due as (
    select
      rental.id as rental_id,
      rental.user_id,
      lower(trim(profile.email)) as customer_email,
      profile.full_name as customer_name,
      coalesce(vehicle.name, 'your rental vehicle') as vehicle_name,
      rental.return_date,
      rental.return_time,
      lower(coalesce(rental.status, '')) as rental_status,
      public.rentmect_rental_timestamp(rental.return_date, rental.return_time)
        at time zone 'America/New_York' as due_at
    from public.rentals as rental
    join public.profiles as profile
      on profile.id = rental.user_id
    left join public.vehicles as vehicle
      on vehicle.id = rental.vehicle_id
    where lower(coalesce(rental.payment_status, '')) = 'paid'
      and coalesce(lower(rental.status), '') not in ('completed', 'cancelled', 'return_initiated')
      and nullif(trim(coalesce(profile.email, '')), '') is not null
      and trim(profile.email) ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
      and rental.return_date is not null
  ),
  reminder_windows as (
    select
      rentals_due.*,
      reminder_window.reminder_type,
      reminder_window.target_send_at
    from rentals_due
    cross join lateral (
      values
        (
          'return_due_previous_morning_email'::text,
          public.rentmect_pre_due_customer_message_time(
            rentals_due.due_at - interval '24 hours',
            rentals_due.due_at
          ),
          true
        ),
        (
          'return_due_3h_email'::text,
          public.rentmect_pre_due_customer_message_time(
            rentals_due.due_at - interval '3 hours',
            rentals_due.due_at
          ),
          true
        ),
        (
          'return_overdue_3h_email'::text,
          public.rentmect_next_visible_customer_message_time(
            rentals_due.due_at + interval '3 hours'
          ),
          rentals_due.rental_status in ('active', 'rented', 'overdue')
        )
    ) as reminder_window(reminder_type, target_send_at, eligible)
    where reminder_window.eligible
      and reminder_window.target_send_at >= p_send_after
      and reminder_window.target_send_at < p_send_before
    order by reminder_window.target_send_at
    limit greatest(least(coalesce(p_limit, 100), 300), 1)
  ),
  queued as (
    insert into public.email_outbox (
      event_key,
      email_type,
      template_id,
      rental_id,
      user_id,
      recipient_email,
      recipient_name,
      payload,
      next_attempt_at
    )
    select
      'return_reminder_email:'
        || reminder_windows.rental_id::text || ':'
        || reminder_windows.reminder_type || ':'
        || extract(epoch from reminder_windows.due_at)::bigint::text,
      reminder_windows.reminder_type,
      template.id,
      reminder_windows.rental_id,
      reminder_windows.user_id,
      reminder_windows.customer_email,
      reminder_windows.customer_name,
      jsonb_build_object(
        'customer_name', coalesce(reminder_windows.customer_name, 'Customer'),
        'customer_first_name', split_part(coalesce(reminder_windows.customer_name, 'Customer'), ' ', 1),
        'vehicle_name', reminder_windows.vehicle_name,
        'return_date', to_char(reminder_windows.return_date, 'Mon FMDD, YYYY'),
        'return_time', coalesce(nullif(trim(reminder_windows.return_time), ''), 'the scheduled time'),
        'return_due_key', extract(epoch from reminder_windows.due_at)::bigint::text,
        'manage_booking_url', 'https://login.rentmect.com',
        'business_phone', '860-558-6031'
      ),
      greatest(reminder_windows.target_send_at, now())
    from reminder_windows
    join public.email_templates as template
      on template.template_key = reminder_windows.reminder_type
     and template.category = 'automated'
     and template.enabled
    on conflict (event_key) do update
    set
      template_id = excluded.template_id,
      recipient_email = excluded.recipient_email,
      recipient_name = excluded.recipient_name,
      payload = excluded.payload,
      status = 'pending',
      attempts = 0,
      next_attempt_at = excluded.next_attempt_at,
      last_error = null,
      updated_at = now()
    where public.email_outbox.status in ('pending', 'failed', 'cancelled')
      and public.email_outbox.recipient_email is distinct from excluded.recipient_email
    returning
      public.email_outbox.id,
      public.email_outbox.email_type,
      public.email_outbox.rental_id
  )
  select queued.id, queued.email_type, queued.rental_id
  from queued;
end;
$$;

comment on function public.queue_due_rental_return_email_reminders(timestamptz, timestamptz, integer)
  is 'Queues idempotent transactional return reminder emails using the live return-reminder timing and quiet-hour rules.';

revoke all on function public.rentmect_pre_due_customer_message_time(timestamptz, timestamptz) from public;
grant execute on function public.rentmect_pre_due_customer_message_time(timestamptz, timestamptz) to service_role;
revoke all on function public.rentmect_next_visible_customer_message_time(timestamptz) from public;
grant execute on function public.rentmect_next_visible_customer_message_time(timestamptz) to service_role;
revoke all on function public.queue_due_rental_return_email_reminders(timestamptz, timestamptz, integer) from public;
grant execute on function public.queue_due_rental_return_email_reminders(timestamptz, timestamptz, integer) to service_role;

-- Keep the return-reminder worker callable for unrelated admin and extension
-- alerts, but make the customer return-SMS claim permanently empty until the
-- business has SMS approval and intentionally ships a later migration.
create or replace function public.claim_due_rental_return_sms_reminders(
  p_send_after timestamptz default now() - interval '15 minutes',
  p_send_before timestamptz default now() + interval '15 minutes',
  p_limit integer default 100
) returns table (
  reminder_id uuid,
  reminder_type text,
  rental_id uuid,
  user_id uuid,
  customer_phone text,
  customer_name text,
  vehicle_name text,
  return_date date,
  return_time text
)
language sql
security definer
set search_path = public
as $$
  select
    null::uuid,
    null::text,
    null::uuid,
    null::uuid,
    null::text,
    null::text,
    null::text,
    null::date,
    null::text
  where false;
$$;

comment on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer)
  is 'Automated customer return SMS is disabled pending messaging approval. This function intentionally returns no rows.';

revoke all on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) from public;
grant execute on function public.claim_due_rental_return_sms_reminders(timestamptz, timestamptz, integer) to service_role;

notify pgrst, 'reload schema';

commit;
