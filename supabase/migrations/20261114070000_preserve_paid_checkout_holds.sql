begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
do $$ begin
 if (select md5(prosrc) from pg_proc where oid='public.expire_stale_customer_checkout_holds()'::regprocedure) <> 'f71d921c5028c74dea01d2b96ff57c28' then raise exception 'Checkout expiry source changed; review before applying'; end if;
end $$;
CREATE OR REPLACE FUNCTION public.expire_stale_customer_checkout_holds() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_cancelled integer := 0;
  v_extension record;
begin
  update public.pending_bookings
    set status = 'expired', updated_at = now()
    where status = 'pending' and expires_at <= now();

  for v_extension in
    update public.rental_extension_requests
      set status = 'cancelled',
          payment_due_at = null,
          updated_at = now()
      where status = 'approved_pending_payment'
        and lower(coalesce(payment_status, 'pending')) not in ('paid','partial','partial_paid','partially_paid')
        and coalesce(payment_amount_cents,0)=0
        and not exists(select 1 from public.rental_payments p
          where (p.stripe_payment_intent_id=rental_extension_requests.stripe_payment_intent_id
             or p.stripe_checkout_session_id=rental_extension_requests.stripe_checkout_session_id)
          and p.status in ('paid','succeeded','complete','completed','partial','partial_paid','partially_paid') and p.total_amount>0)
        and payment_due_at <= now()
      returning id, rental_id, user_id
  loop
    perform public.release_extension_calendar_hold(v_extension.id);
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    ) values (
      v_extension.rental_id, v_extension.user_id, null,
      'extension_payment_deadline_expired',
      jsonb_build_object('extension_request_id', v_extension.id, 'expired_at', now())
    );
  end loop;

  with cancelled as (
    update public.rentals
      set status = 'cancelled',
          cancelled_at = now(),
          cancellation_reason = case
            when booking_source = 'admin_manual' then 'Payment deadline expired'
            else '25-minute checkout deadline expired'
          end,
          updated_at = now()
      where coalesce(lower(payment_status), 'pending') not in ('paid','partial','partial_paid','partially_paid')
        and coalesce(payment_amount_cents,0)=0
        and coalesce(deposit_held_amount,0)=0
        and not exists(select 1 from public.rental_charge_items c where c.rental_id=rentals.id
          and c.charge_type in ('rental_amendment','rental_installment') and c.status='paid' and c.total_amount>0)
        and not exists (select 1 from public.rental_payments p where p.rental_id=rentals.id
          and p.status in ('paid','succeeded','complete','completed','partial','partial_paid','partially_paid')
          and p.total_amount>0)
        and not exists (select 1 from public.external_payment_receipts p where p.rental_id=rentals.id
          and p.status='posted' and p.amount_cents>0)
        and lower(coalesce(status, 'pending')) in
          ('pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup')
        and coalesce(payment_due_at, checkout_expires_at) <= now()
      returning id, user_id, booking_source, stripe_checkout_session_id
  ), audited as (
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    )
    select id, user_id, null, 'unpaid_reservation_expired',
           jsonb_build_object(
             'expired_at', now(),
             'booking_source', booking_source,
             'stripe_checkout_session_id', stripe_checkout_session_id
           )
    from cancelled
    returning rental_id
  )
  select count(*) into v_cancelled from audited;

  return v_cancelled;
end;
$$;
commit;
