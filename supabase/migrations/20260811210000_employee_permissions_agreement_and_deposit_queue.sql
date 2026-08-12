begin;

-- Staff roles intentionally sit beside profiles.role. Existing RLS continues to
-- recognize role = 'admin', while staff_role provides the business-facing role
-- and shared Employee permission set.
alter table public.profiles
  add column if not exists staff_role text;

update public.profiles
set staff_role = case when lower(coalesce(email, '')) = 'anconamgt@aol.com'
  then 'operations_manager' else 'owner' end
where role = 'admin' and staff_role is null;

update public.profiles
set staff_role = 'customer'
where staff_role is null;

alter table public.profiles alter column staff_role set default 'customer';
alter table public.profiles alter column staff_role set not null;

alter table public.profiles drop constraint if exists profiles_staff_role_check;
alter table public.profiles add constraint profiles_staff_role_check
  check (staff_role in ('owner', 'operations_manager', 'employee', 'customer'));

create table if not exists public.employee_permissions (
  permission_key text primary key,
  label text not null,
  category text not null,
  description text not null default '',
  enabled boolean not null default true,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.employee_permissions (permission_key, label, category, description, enabled) values
  ('tab.dashboard', 'Dashboard', 'Visible tabs', 'View the operations dashboard.', true),
  ('tab.queue', 'Queue', 'Visible tabs', 'View and work operational queue items.', true),
  ('tab.payments', 'Payments', 'Visible tabs', 'View payment activity and balances.', true),
  ('tab.tolls', 'Tolls', 'Visible tabs', 'View and manage toll activity.', true),
  ('tab.calendar', 'Calendar', 'Visible tabs', 'View and edit the fleet calendar.', true),
  ('tab.rentals', 'Rentals', 'Visible tabs', 'View and manage rentals.', true),
  ('tab.vehicles', 'Vehicles', 'Visible tabs', 'View and manage fleet vehicles.', true),
  ('tab.customers', 'Customers', 'Visible tabs', 'View and manage customers.', true),
  ('tab.communications', 'Communications', 'Visible tabs', 'Send messages and manage templates.', true),
  ('tab.audit', 'Audit Log', 'Visible tabs', 'View staff audit history.', true),
  ('tab.settings', 'Settings', 'Visible tabs', 'View operational settings.', true),
  ('booking.create', 'Create bookings', 'Rentals & bookings', 'Create customer bookings.', true),
  ('rental.edit', 'Edit rental details', 'Rentals & bookings', 'Change rental dates, times, vehicle, price, and deposit.', true),
  ('rental.cancel', 'Cancel rentals', 'Rentals & bookings', 'Cancel eligible rentals.', true),
  ('rental.discount', 'Apply discounts', 'Rentals & bookings', 'Add or edit rental discounts.', true),
  ('rental.return', 'Complete returns', 'Rentals & bookings', 'Complete vehicle return inspections.', true),
  ('payment.collect', 'Collect payments', 'Payments & deposits', 'Use Stripe, saved card, cash, or another external method.', true),
  ('payment.refund', 'Refund rental payments', 'Payments & deposits', 'Refund eligible captured rental payments.', true),
  ('deposit.resolve', 'Resolve deposits', 'Payments & deposits', 'Refund, externally return, transfer, waive, or escalate deposits.', true),
  ('charge.manage', 'Manage rental charges', 'Payments & deposits', 'Add, collect, or waive toll, damage, cleaning, late, and manual charges.', true),
  ('vehicle.manage', 'Manage fleet', 'Fleet', 'Edit pricing, availability, publishing, and vehicle details.', true),
  ('customer.manage', 'Manage customers', 'Customers', 'Edit customer records and approved deletes.', true),
  ('communications.send', 'Send customer messages', 'Communications', 'Send preloaded email and text templates.', true),
  ('communications.templates', 'Manage communication templates', 'Communications', 'Create and edit approved templates.', true),
  ('reports.financial', 'View financial reports', 'Sensitive access', 'View payments and Stripe-linked financial information.', true),
  ('audit.view', 'View audit logs', 'Sensitive access', 'View staff action history.', true),
  ('override.emergency', 'Use emergency overrides', 'Sensitive access', 'Use approved bypass and emergency workflows.', true),
  ('settings.operational', 'Change operational settings', 'Sensitive access', 'Change pricing, billing, availability, and booking settings.', true)
on conflict (permission_key) do update set
  label = excluded.label,
  category = excluded.category,
  description = excluded.description;

alter table public.employee_permissions enable row level security;

create or replace function public.rentmect_is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and staff_role in ('owner', 'operations_manager', 'employee')
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.rentmect_is_staff(); $$;

create or replace function public.rentmect_has_permission(p_permission_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when profile.staff_role in ('owner', 'operations_manager') then true
    when profile.staff_role = 'employee' then coalesce((
      select permission.enabled from public.employee_permissions permission
      where permission.permission_key = p_permission_key
    ), false)
    else false
  end
  from public.profiles profile
  where profile.id = auth.uid() and profile.role = 'admin';
$$;

create or replace function public.get_admin_staff_context()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'staff_role', profile.staff_role,
    'can_manage_employee_permissions', profile.staff_role = 'owner'
      or lower(coalesce(profile.email, '')) = 'anconamgt@aol.com',
    'permissions', coalesce((
      select jsonb_object_agg(permission.permission_key,
        case when profile.staff_role in ('owner', 'operations_manager') then true else permission.enabled end)
      from public.employee_permissions permission
    ), '{}'::jsonb)
  )
  from public.profiles profile
  where profile.id = auth.uid() and profile.role = 'admin';
$$;

create or replace function public.admin_set_employee_permission(
  p_permission_key text,
  p_enabled boolean
) returns public.employee_permissions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor public.profiles%rowtype;
  v_permission public.employee_permissions%rowtype;
  v_previous boolean;
begin
  select * into v_actor from public.profiles where id = auth.uid();
  if not found or v_actor.role <> 'admin' or not (
    v_actor.staff_role = 'owner' or lower(coalesce(v_actor.email, '')) = 'anconamgt@aol.com'
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
$$;

drop policy if exists "Staff can read Employee permissions" on public.employee_permissions;
create policy "Staff can read Employee permissions"
  on public.employee_permissions for select to authenticated
  using (public.rentmect_is_staff());
revoke insert, update, delete on public.employee_permissions from anon, authenticated;
grant select on public.employee_permissions to authenticated;
revoke all on function public.admin_set_employee_permission(text, boolean) from public;
grant execute on function public.admin_set_employee_permission(text, boolean) to authenticated;
grant execute on function public.get_admin_staff_context() to authenticated;
grant execute on function public.rentmect_has_permission(text) to authenticated;

-- A completed return with money still held creates one durable queue item. The
-- unique rental key and upsert make repeated completion/webhook events safe.
create table if not exists public.deposit_action_tasks (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null unique references public.rentals(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  status text not null default 'action_required'
    check (status in ('action_required', 'blocked', 'release_pending', 'escalated', 'resolved')),
  deposit_amount numeric(10,2) not null default 0 check (deposit_amount >= 0),
  blockers jsonb not null default '[]'::jsonb,
  escalated_note text,
  resolution_method text,
  resolution_reference text,
  resolution_note text,
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists deposit_action_tasks_status_created_idx
  on public.deposit_action_tasks (status, created_at desc);

create or replace function public.rentmect_deposit_blockers(p_rental_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(blocker order by blocker ->> 'type'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'type', 'unpaid_charge', 'label', coalesce(charge.name, initcap(replace(charge.charge_type, '_', ' '))),
      'amount', charge.total_amount, 'id', charge.id
    ) blocker
    from public.rental_charge_items charge
    where charge.rental_id = p_rental_id
      and charge.included_in_initial_payment = false
      and charge.status in ('pending', 'checkout_open', 'failed')
    union all
    select jsonb_build_object(
      'type', 'stripe_reconciliation', 'label', issue.issue_type,
      'amount', issue.amount, 'id', issue.id
    )
    from public.stripe_reconciliation_issues issue
    where issue.rental_id = p_rental_id and issue.status in ('processing', 'open')
    union all
    select jsonb_build_object(
      'type', 'vehicle_report', 'label', coalesce(report.issue_type, report.report_type, 'Vehicle report'),
      'amount', coalesce(report.final_charge_amount, report.estimated_cost, 0), 'id', report.id
    )
    from public.vehicle_reports report
    where report.rental_id = p_rental_id
      and lower(coalesce(report.status, 'open')) not in ('resolved', 'closed', 'dismissed')
  ) blockers;
$$;

create or replace function public.sync_deposit_action_task(p_rental_id uuid)
returns public.deposit_action_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
  v_task public.deposit_action_tasks%rowtype;
  v_blockers jsonb := '[]'::jsonb;
  v_held numeric := 0;
  v_next_status text;
begin
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then return null; end if;
  v_held := greatest(coalesce(v_rental.deposit_held_amount, 0), 0);

  if lower(coalesce(v_rental.status, '')) <> 'completed' then return null; end if;
  if v_held <= 0 or lower(coalesce(v_rental.deposit_status, '')) in ('released', 'transferred') then
    update public.deposit_action_tasks
    set status = 'resolved', deposit_amount = 0,
        resolution_method = coalesce(resolution_method, v_rental.deposit_status, 'released'),
        resolved_at = coalesce(resolved_at, now()), updated_at = now()
    where rental_id = p_rental_id and status <> 'resolved'
    returning * into v_task;
    return v_task;
  end if;

  v_blockers := public.rentmect_deposit_blockers(p_rental_id);
  v_next_status := case
    when lower(coalesce(v_rental.deposit_status, '')) = 'release_pending' then 'release_pending'
    when jsonb_array_length(v_blockers) > 0 then 'blocked'
    else 'action_required'
  end;

  insert into public.deposit_action_tasks (rental_id, user_id, status, deposit_amount, blockers)
  values (v_rental.id, v_rental.user_id, v_next_status, v_held, v_blockers)
  on conflict (rental_id) do update set
    user_id = excluded.user_id,
    status = case when public.deposit_action_tasks.status = 'escalated' and excluded.status <> 'release_pending'
      then 'escalated' else excluded.status end,
    deposit_amount = excluded.deposit_amount,
    blockers = excluded.blockers,
    updated_at = now()
  returning * into v_task;
  return v_task;
end;
$$;

create or replace function public.sync_deposit_action_task_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_rental_id uuid;
begin
  v_rental_id := coalesce(nullif(v_row ->> 'rental_id', ''), nullif(v_row ->> 'id', ''))::uuid;
  perform public.sync_deposit_action_task(v_rental_id);
  return coalesce(new, old);
end;
$$;

drop trigger if exists sync_deposit_task_from_rental on public.rentals;
create trigger sync_deposit_task_from_rental
after insert or update of status, deposit_status, deposit_held_amount, deposit_released_amount
on public.rentals for each row execute function public.sync_deposit_action_task_trigger();

drop trigger if exists sync_deposit_task_from_charge on public.rental_charge_items;
create trigger sync_deposit_task_from_charge
after insert or update or delete on public.rental_charge_items
for each row execute function public.sync_deposit_action_task_trigger();

drop trigger if exists sync_deposit_task_from_reconciliation on public.stripe_reconciliation_issues;
create trigger sync_deposit_task_from_reconciliation
after insert or update or delete on public.stripe_reconciliation_issues
for each row execute function public.sync_deposit_action_task_trigger();

drop trigger if exists sync_deposit_task_from_report on public.vehicle_reports;
create trigger sync_deposit_task_from_report
after insert or update or delete on public.vehicle_reports
for each row execute function public.sync_deposit_action_task_trigger();

create or replace function public.admin_escalate_deposit_task(p_rental_id uuid, p_note text)
returns public.deposit_action_tasks
language plpgsql
security definer
set search_path = public
as $$
declare v_task public.deposit_action_tasks%rowtype;
begin
  if coalesce(public.rentmect_has_permission('deposit.resolve'), false) is not true then raise exception 'Deposit resolution permission is required.'; end if;
  if nullif(trim(p_note), '') is null then raise exception 'An escalation note is required.'; end if;
  perform public.sync_deposit_action_task(p_rental_id);
  update public.deposit_action_tasks set status = 'escalated', escalated_note = trim(p_note), updated_at = now()
  where rental_id = p_rental_id and status <> 'resolved' returning * into v_task;
  if not found then raise exception 'No open deposit action exists for this rental.'; end if;
  perform public.record_admin_audit_event('deposit_task.escalated', 'rental', p_rental_id::text, jsonb_build_object('note', trim(p_note)));
  return v_task;
end;
$$;

create or replace function public.admin_record_external_deposit_release(
  p_rental_id uuid,
  p_method text,
  p_reference text default null,
  p_note text default null
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare v_rental public.rentals%rowtype; v_task public.deposit_action_tasks%rowtype;
begin
  if coalesce(public.rentmect_has_permission('deposit.resolve'), false) is not true then raise exception 'Deposit resolution permission is required.'; end if;
  if lower(trim(coalesce(p_method, ''))) not in ('cash', 'check', 'bank_transfer', 'other') then
    raise exception 'Choose cash, check, bank transfer, or other.';
  end if;
  v_rental := public.admin_record_local_deposit_release(p_rental_id);
  update public.deposit_action_tasks set
    status = 'resolved', resolution_method = lower(trim(p_method)),
    resolution_reference = nullif(trim(p_reference), ''), resolution_note = nullif(trim(p_note), ''),
    resolved_by = auth.uid(), resolved_at = now(), updated_at = now()
  where rental_id = p_rental_id returning * into v_task;
  perform public.record_admin_audit_event(
    'security_deposit.external_release_recorded', 'rental', p_rental_id::text,
    jsonb_build_object('method', lower(trim(p_method)), 'reference', nullif(trim(p_reference), ''), 'note', nullif(trim(p_note), ''))
  );
  return v_rental;
end;
$$;

alter table public.deposit_action_tasks enable row level security;
drop policy if exists "Staff can read deposit action tasks" on public.deposit_action_tasks;
create policy "Staff can read deposit action tasks" on public.deposit_action_tasks
  for select to authenticated using (public.rentmect_is_staff());
revoke insert, update, delete on public.deposit_action_tasks from anon, authenticated;
grant select on public.deposit_action_tasks to authenticated;
revoke all on function public.admin_escalate_deposit_task(uuid, text) from public;
revoke all on function public.admin_record_external_deposit_release(uuid, text, text, text) from public;
grant execute on function public.admin_escalate_deposit_task(uuid, text) to authenticated;
grant execute on function public.admin_record_external_deposit_release(uuid, text, text, text) to authenticated;

insert into public.deposit_action_tasks (rental_id, user_id, status, deposit_amount, blockers)
select rental.id, rental.user_id,
  case when jsonb_array_length(public.rentmect_deposit_blockers(rental.id)) > 0 then 'blocked' else 'action_required' end,
  greatest(coalesce(rental.deposit_held_amount, 0), 0),
  public.rentmect_deposit_blockers(rental.id)
from public.rentals rental
where lower(coalesce(rental.status, '')) = 'completed'
  and lower(coalesce(rental.deposit_status, '')) in ('held', 'adjustment_refund_due', 'release_pending')
  and coalesce(rental.deposit_held_amount, 0) > 0
on conflict (rental_id) do update set
  deposit_amount = excluded.deposit_amount,
  blockers = excluded.blockers,
  status = case when public.deposit_action_tasks.status = 'escalated' then 'escalated' else excluded.status end,
  updated_at = now();

insert into public.email_templates (
  template_key, name, category, trigger_key, subject, preheader, html_body, text_body, enabled
) values (
  'manual_agreement_signature_required',
  'Agreement Signature Required',
  'manual',
  null,
  'Signature required for your Rent Me CT rental',
  'Please review and sign your rental agreement before pickup.',
  '<h1>Your rental agreement needs your signature.</h1><p>Hi {{customer_first_name}},</p><p>Your agreement for <strong>{{vehicle_name}}</strong> has not been signed yet.</p><p>Please review and sign it before your scheduled pickup.</p><p><a href="{{agreement_signing_url}}">Review and sign the agreement</a></p><p>If you have questions, call {{business_phone}}.</p>',
  'Hi {{customer_first_name}}, your Rent Me CT agreement for {{vehicle_name}} still needs your signature. Review and sign it here: {{agreement_signing_url}}. Questions: {{business_phone}}.',
  true
)
on conflict (template_key) do update set
  name = excluded.name, category = excluded.category, subject = excluded.subject,
  preheader = excluded.preheader, html_body = excluded.html_body,
  text_body = excluded.text_body, enabled = true,
  version = public.email_templates.version + 1, updated_at = now();

commit;
