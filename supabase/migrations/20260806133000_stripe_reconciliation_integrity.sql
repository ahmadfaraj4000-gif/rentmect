begin;

-- A Stripe payment/refund must remain visible even when the business-state
-- update fails. This table is the durable admin queue for those exceptions.
create table if not exists public.stripe_reconciliation_issues (
  id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  stripe_event_id text,
  checkout_session_id text,
  payment_intent_id text,
  refund_id text,
  issue_type text not null,
  target_type text not null default 'unknown'
    check (target_type in ('rental', 'extension', 'charge', 'unknown')),
  target_id uuid,
  rental_id uuid references public.rentals(id) on delete set null,
  extension_request_id uuid references public.rental_extension_requests(id) on delete set null,
  amount numeric(10,2) not null default 0 check (amount >= 0),
  currency text not null default 'usd',
  status text not null default 'processing'
    check (status in ('processing', 'open', 'resolved', 'refunded')),
  error_message text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists stripe_reconciliation_issues_status_created_idx
  on public.stripe_reconciliation_issues (status, created_at desc);
create index if not exists stripe_reconciliation_issues_rental_created_idx
  on public.stripe_reconciliation_issues (rental_id, created_at desc);
create index if not exists stripe_reconciliation_issues_payment_intent_idx
  on public.stripe_reconciliation_issues (payment_intent_id)
  where payment_intent_id is not null;

alter table public.stripe_reconciliation_issues enable row level security;
drop policy if exists "Admins can read Stripe reconciliation issues"
  on public.stripe_reconciliation_issues;
create policy "Admins can read Stripe reconciliation issues"
on public.stripe_reconciliation_issues
for select
to authenticated
using (public.is_admin());

revoke all on table public.stripe_reconciliation_issues from public, anon;
grant select on table public.stripe_reconciliation_issues to authenticated;
grant all on table public.stripe_reconciliation_issues to service_role;

create or replace function public.upsert_stripe_reconciliation_issue(
  p_dedupe_key text,
  p_issue_type text,
  p_status text,
  p_stripe_event_id text default null,
  p_checkout_session_id text default null,
  p_payment_intent_id text default null,
  p_refund_id text default null,
  p_target_type text default 'unknown',
  p_target_id uuid default null,
  p_rental_id uuid default null,
  p_extension_request_id uuid default null,
  p_amount numeric default 0,
  p_currency text default 'usd',
  p_error_message text default null,
  p_payload jsonb default '{}'::jsonb
) returns public.stripe_reconciliation_issues
language plpgsql
security definer
set search_path = public
as $$
declare
  v_issue public.stripe_reconciliation_issues%rowtype;
begin
  if coalesce(trim(p_dedupe_key), '') = '' then
    raise exception 'A reconciliation dedupe key is required.';
  end if;
  if p_status not in ('processing', 'open', 'resolved', 'refunded') then
    raise exception 'Invalid reconciliation status.';
  end if;
  if p_target_type not in ('rental', 'extension', 'charge', 'unknown') then
    raise exception 'Invalid reconciliation target type.';
  end if;

  insert into public.stripe_reconciliation_issues (
    dedupe_key, stripe_event_id, checkout_session_id, payment_intent_id,
    refund_id, issue_type, target_type, target_id, rental_id,
    extension_request_id, amount, currency, status, error_message, payload,
    resolved_at
  ) values (
    trim(p_dedupe_key), p_stripe_event_id, p_checkout_session_id,
    p_payment_intent_id, p_refund_id, p_issue_type, p_target_type,
    p_target_id, p_rental_id, p_extension_request_id,
    greatest(coalesce(p_amount, 0), 0), lower(coalesce(p_currency, 'usd')),
    p_status, nullif(left(coalesce(p_error_message, ''), 2000), ''),
    coalesce(p_payload, '{}'::jsonb),
    case when p_status in ('resolved', 'refunded') then now() else null end
  )
  on conflict (dedupe_key) do update set
    stripe_event_id = coalesce(excluded.stripe_event_id, stripe_reconciliation_issues.stripe_event_id),
    checkout_session_id = coalesce(excluded.checkout_session_id, stripe_reconciliation_issues.checkout_session_id),
    payment_intent_id = coalesce(excluded.payment_intent_id, stripe_reconciliation_issues.payment_intent_id),
    refund_id = coalesce(excluded.refund_id, stripe_reconciliation_issues.refund_id),
    issue_type = excluded.issue_type,
    target_type = excluded.target_type,
    target_id = coalesce(excluded.target_id, stripe_reconciliation_issues.target_id),
    rental_id = coalesce(excluded.rental_id, stripe_reconciliation_issues.rental_id),
    extension_request_id = coalesce(excluded.extension_request_id, stripe_reconciliation_issues.extension_request_id),
    amount = greatest(excluded.amount, stripe_reconciliation_issues.amount),
    currency = excluded.currency,
    status = excluded.status,
    error_message = excluded.error_message,
    payload = stripe_reconciliation_issues.payload || excluded.payload,
    updated_at = now(),
    resolved_at = case
      when excluded.status in ('resolved', 'refunded') then now()
      else null
    end
  returning * into v_issue;

  return v_issue;
end;
$$;

revoke all on function public.upsert_stripe_reconciliation_issue(
  text, text, text, text, text, text, text, text, uuid, uuid, uuid,
  numeric, text, text, jsonb
) from public, anon, authenticated;
grant execute on function public.upsert_stripe_reconciliation_issue(
  text, text, text, text, text, text, text, text, uuid, uuid, uuid,
  numeric, text, text, jsonb
) to service_role;

alter table public.rental_payment_refunds
  add column if not exists source_type text not null default 'admin_rental_payment',
  add column if not exists extension_request_id uuid
    references public.rental_extension_requests(id) on delete set null,
  add column if not exists stripe_event_id text;

create index if not exists rental_payment_refunds_extension_created_idx
  on public.rental_payment_refunds (extension_request_id, created_at desc)
  where extension_request_id is not null;

-- Preserve every existing admin notification type while adding a dedicated
-- urgent path for captured money/refunds that require reconciliation.
do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_constraint
    where conrelid = 'public.admin_notification_events'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%event_type%'
  loop
    execute format(
      'alter table public.admin_notification_events drop constraint %I',
      constraint_name
    );
  end loop;

  alter table public.admin_notification_events
    add constraint admin_notification_events_event_type_check
    check (event_type in (
      'new_booking', 'document_pending_review', 'return_due_today',
      'maintenance_due', 'maintenance_due_soon', 'maintenance_override',
      'extension_requested', 'extension_approved', 'emergency_exception_created',
      'rental_payment_received', 'extension_payment_received', 'rental_overdue',
      'vehicle_price_changed', 'rental_return_initiated', 'customer_message_received',
      'vehicle_report_submitted', 'toll_needs_review', 'toll_sync_failed',
      'customer_charge_failed', 'refund_failed', 'deposit_release_failed',
      'rental_cancelled', 'rental_ready_for_pickup', 'identity_verification_failed',
      'extension_payment_failed', 'rental_payment_failed', 'chargeback_created',
      'stripe_reconciliation_required'
    ));
end
$$;

do $$
begin
  alter publication supabase_realtime add table public.rental_extension_requests;
exception when duplicate_object then null;
end
$$;
do $$
begin
  alter publication supabase_realtime add table public.rental_payment_refunds;
exception when duplicate_object then null;
end
$$;
do $$
begin
  alter publication supabase_realtime add table public.rental_payments;
exception when duplicate_object then null;
end
$$;
do $$
begin
  alter publication supabase_realtime add table public.rental_charge_items;
exception when duplicate_object then null;
end
$$;
do $$
begin
  alter publication supabase_realtime add table public.rental_deposit_allocations;
exception when duplicate_object then null;
end
$$;
do $$
begin
  alter publication supabase_realtime add table public.stripe_reconciliation_issues;
exception when duplicate_object then null;
end
$$;

commit;
