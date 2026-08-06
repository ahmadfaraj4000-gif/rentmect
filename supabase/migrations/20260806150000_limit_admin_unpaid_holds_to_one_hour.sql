begin;

-- Customer website holds remain 25 minutes. Admin-created unpaid rentals may
-- reserve inventory for at most one hour, including explicit deadline changes.
create or replace function public.initialize_rental_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_admin() and new.source_pending_booking_id is null then
      new.booking_source := 'admin_manual';
    elsif coalesce(new.booking_source, '') = '' then
      new.booking_source := 'customer_portal';
    end if;

    if coalesce(lower(new.payment_status), 'pending') <> 'paid' then
      if new.booking_source = 'admin_manual' then
        new.payment_due_at := least(
          coalesce(new.payment_due_at, now() + interval '1 hour'),
          now() + interval '1 hour'
        );
        new.checkout_expires_at := null;
      else
        new.checkout_expires_at := coalesce(new.checkout_expires_at, now() + interval '25 minutes');
        new.payment_due_at := coalesce(new.payment_due_at, new.checkout_expires_at);
      end if;
    end if;
  end if;

  if coalesce(lower(new.payment_status), 'pending') = 'paid' then
    new.checkout_expires_at := null;
    new.payment_due_at := null;
  end if;

  if tg_op = 'UPDATE'
     and lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;

  return new;
end;
$$;

create or replace function public.admin_extend_rental_payment_deadline(
  p_rental_id uuid,
  p_payment_due_at timestamptz,
  p_reason text
) returns public.rentals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then
    raise exception 'Admin access is required.';
  end if;
  if p_payment_due_at is null or p_payment_due_at <= now() then
    raise exception 'Choose a future payment deadline.';
  end if;
  if p_payment_due_at > now() + interval '1 hour' then
    raise exception 'Unpaid reservation holds cannot exceed one hour.';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Enter a reason for changing the deadline.';
  end if;

  update public.rentals
    set payment_due_at = p_payment_due_at,
        checkout_expires_at = case
          when booking_source = 'admin_manual' then null else p_payment_due_at
        end,
        updated_at = now()
    where id = p_rental_id
      and coalesce(lower(payment_status), 'pending') <> 'paid'
      and lower(coalesce(status, '')) not in ('cancelled', 'completed', 'active', 'overdue', 'return_initiated')
    returning * into v_rental;

  if not found then raise exception 'Only an open unpaid reservation can be extended.'; end if;

  insert into public.rental_audit_events (rental_id, user_id, actor_id, event_type, event_payload)
  values (
    v_rental.id, v_rental.user_id, v_admin_id, 'admin_payment_deadline_extended',
    jsonb_build_object('payment_due_at', p_payment_due_at, 'reason', trim(p_reason))
  );
  return v_rental;
end;
$$;

revoke all on function public.admin_extend_rental_payment_deadline(uuid, timestamptz, text) from public;
grant execute on function public.admin_extend_rental_payment_deadline(uuid, timestamptz, text) to authenticated;

-- Shorten existing open admin-created unpaid reservations without lengthening
-- any deadline that is already sooner than one hour from migration time.
with candidates as (
  select id, user_id, payment_due_at as previous_payment_due_at
  from public.rentals
  where booking_source = 'admin_manual'
    and coalesce(lower(payment_status), 'pending') <> 'paid'
    and lower(coalesce(status, '')) in
      ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup')
    and (payment_due_at is null or payment_due_at > now() + interval '1 hour')
  for update
), shortened as (
  update public.rentals rental
  set payment_due_at = now() + interval '1 hour',
      checkout_expires_at = null,
      updated_at = now()
  from candidates candidate
  where rental.id = candidate.id
  returning rental.id, rental.user_id, candidate.previous_payment_due_at, rental.payment_due_at
)
insert into public.rental_audit_events (
  rental_id, user_id, actor_id, event_type, event_payload
)
select
  id,
  user_id,
  null,
  'admin_unpaid_deadline_shortened_to_one_hour',
  jsonb_build_object(
    'previous_payment_due_at', previous_payment_due_at,
    'payment_due_at', payment_due_at,
    'source', 'one_hour_hold_policy'
  )
from shortened;

notify pgrst, 'reload schema';

commit;
