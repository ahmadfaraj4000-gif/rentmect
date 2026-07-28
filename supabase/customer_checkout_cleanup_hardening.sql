-- Safely removes an unpaid rental created immediately before a website checkout
-- hold failed to attach. This prevents an invisible orphan row from blocking a car.

create or replace function public.cancel_customer_unattached_rental(
  p_rental_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cancelled boolean := false;
begin
  if v_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  update public.rentals
  set status = 'cancelled',
      updated_at = now()
  where id = p_rental_id
    and user_id = v_user_id
    and checkout_expires_at is null
    and coalesce(lower(payment_status), 'pending') <> 'paid'
    and stripe_checkout_session_id is null
    and lower(coalesce(status, 'pending')) in ('pending', 'documents_needed', 'document_review');

  v_cancelled := found;

  if v_cancelled then
    insert into public.rental_audit_events (
      rental_id, user_id, actor_id, event_type, event_payload
    ) values (
      p_rental_id,
      v_user_id,
      v_user_id,
      'customer_unattached_rental_cancelled',
      jsonb_build_object('source', 'client_portal', 'reason', 'checkout_hold_attach_failed')
    );
  end if;

  return v_cancelled;
end;
$$;

revoke all on function public.cancel_customer_unattached_rental(uuid) from public;
grant execute on function public.cancel_customer_unattached_rental(uuid) to authenticated;
