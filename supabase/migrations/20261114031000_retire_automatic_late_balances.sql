-- Apply after retiring open Stripe attempts through the protected waiver flow.
begin;
set local lock_timeout='2s';
set local statement_timeout='30s';
do $$ begin
 perform 1 from public.rental_charge_items
 where source_type='late_return' and status in ('pending','failed','checkout_open')
 order by id for update;
 if exists(select 1 from public.external_payment_receipts r
   join public.external_payment_allocations a on a.receipt_id=r.id
   join public.rental_charge_items c on c.id=a.charge_id
   where r.status='pending' and c.source_type='late_return') then
  raise exception 'Retire pending allocated payments containing automatic late charges before this cleanup.';
 end if;
 if exists(select 1 from public.rental_charge_items where source_type='late_return'
   and status in ('pending','failed','checkout_open')
   and (stripe_checkout_session_id is not null or stripe_payment_intent_id is not null
     or checkout_creation_token is not null)) then
  raise exception 'Retire open automatic late-charge payment attempts before applying this cleanup.';
 end if;
end $$;
-- Preserve original amounts and payments; waive only the unpaid remainder.
with candidates as materialized (
 select * from public.rental_charge_items where source_type='late_return'
 and status in ('pending','failed','checkout_open') for update
), audit as (
 insert into public.rental_audit_events(rental_id,user_id,event_type,event_payload)
 select rental_id,user_id,'automatic_late_policy_retirement',jsonb_build_object(
  'charge_id',id,'previous_status',status,'original_amount',total_amount,
  'remaining_amount',greatest(0,total_amount-(allocated_payment_cents+allocated_waiver_cents+allocated_deposit_cents)/100.0),
  'reason','Automatic late fees and rental-day assessments retired by owner-approved policy',
  'policy_version','2026-11-13-admin-return') from candidates returning rental_id
)
update public.rental_charge_items c set status='waived',updated_at=now()
from candidates old where c.id=old.id;
-- Cancel unsent collection notices; retain sent-message history.
update public.email_outbox o set status='cancelled',
 last_error='Automatic late-charge policy retired.',updated_at=now()
where o.status in ('pending','failed') and exists (
 select 1 from public.rental_charge_items c where c.source_type='late_return' and c.status='waived'
 and o.event_key in ('additional_charge_due:'||c.id::text,'additional_charge_waived:'||c.id::text));
commit;
