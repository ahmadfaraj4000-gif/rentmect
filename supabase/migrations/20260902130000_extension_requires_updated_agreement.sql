begin;

-- An approved extension changes the dates in the Rental Addendum. Preserve the
-- prior signed snapshot in rental_signatures, invalidate the current snapshot,
-- and force the agreement workflow step to be completed again.
create or replace function public.require_updated_agreement_after_extension_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_email text;
begin
  if new.status <> 'approved_pending_payment'
     or old.status = 'approved_pending_payment' then
    return new;
  end if;

  select profile.email into v_actor_email
  from public.profiles profile
  where profile.id = new.decided_by;

  update public.rentals
  set agreement_signed = false,
      agreement_version = null,
      agreement_snapshot = null,
      agreement_hash = null,
      agreement_signed_at = null,
      agreement_signature_name = null,
      agreement_ip = null,
      agreement_user_agent = null,
      updated_at = now()
  where id = new.rental_id;

  delete from public.rental_step_completions
  where rental_id = new.rental_id
    and step_key = 'agreement';

  insert into public.rental_audit_events (
    rental_id, user_id, actor_id, event_type, event_payload
  ) values (
    new.rental_id,
    new.user_id,
    new.decided_by,
    'rental_agreement_resign_required',
    jsonb_build_object(
      'extension_request_id', new.id,
      'requested_return_date', new.requested_return_date,
      'requested_return_time', new.requested_return_time,
      'actor_email', v_actor_email,
      'reason', 'Approved extension changes the Rental Addendum dates'
    )
  );

  return new;
end;
$$;

drop trigger if exists rental_extension_requires_updated_agreement
  on public.rental_extension_requests;
create trigger rental_extension_requires_updated_agreement
after update of status on public.rental_extension_requests
for each row execute function public.require_updated_agreement_after_extension_approval();

commit;
