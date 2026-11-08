-- An unapproved, unpaid request cannot extend a completed/cancelled rental.
-- Keep its row and audit history. Approved requests and payment attempts need
-- their existing settlement workflows and are deliberately excluded.
create or replace function public.rentmect_retire_unapproved_closed_extensions()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 update public.rental_extension_requests e
 set status='cancelled',decided_at=coalesce(e.decided_at,now()),updated_at=now(),
   admin_note=concat_ws(E'\n',nullif(e.admin_note,''),'System: unapproved, unpaid request retired because its rental is '||new.status||'.')
 where e.rental_id=new.id and e.status='pending' and e.payment_status='not_due'
   and e.paid_at is null and e.activated_at is null and e.stripe_checkout_session_id is null
   and e.stripe_payment_intent_id is null and e.replacement_rental_id is null;
 return new;
end $$;
revoke all on function public.rentmect_retire_unapproved_closed_extensions() from public,anon,authenticated;
drop trigger if exists rental_retire_unapproved_closed_extensions on public.rentals;
create trigger rental_retire_unapproved_closed_extensions after update of status on public.rentals
for each row when (new.status in ('completed','cancelled') and old.status is distinct from new.status)
execute function public.rentmect_retire_unapproved_closed_extensions();

update public.rental_extension_requests e
set status='cancelled',decided_at=coalesce(e.decided_at,now()),updated_at=now(),
 admin_note=concat_ws(E'\n',nullif(e.admin_note,''),'System: unapproved, unpaid request retired because its rental is '||r.status||'.')
from public.rentals r
where r.id=e.rental_id and r.status in ('completed','cancelled')
 and e.status='pending' and e.payment_status='not_due'
 and e.paid_at is null and e.activated_at is null and e.stripe_checkout_session_id is null
 and e.stripe_payment_intent_id is null and e.replacement_rental_id is null;
