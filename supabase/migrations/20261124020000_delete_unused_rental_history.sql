begin;
-- A separate confirmation contract keeps older open sessions from treating an
-- archive confirmation as consent to erase a signed agreement.
create function public.delete_unused_rental(p_rental_id uuid, p_confirm text default null)
returns text language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.rentals;
begin
  -- The existing review checks staff identity, locks this rental and checks
  -- pickup, checkout, payment and deposit state. A null confirmation is read-only.
  perform public.remove_unused_rental(p_rental_id, null);
  select * into strict r from public.rentals where id=p_rental_id;
  perform 1 from public.external_payment_receipts where rental_id=r.id for update;
  if exists(select from public.external_payment_receipts where rental_id=r.id
            and (status <> 'cancelled' or posted_at is not null or refunded_at is not null))
     or exists(select from public.rental_payments where rental_id=r.id)
     or exists(select from public.rental_payment_refunds where rental_id=r.id)
     or exists(select from public.rental_deposit_allocations where r.id in (source_rental_id,holder_rental_id))
     or exists(select from public.rental_charge_items where rental_id=r.id and
            (paid_at is not null or status='paid' or allocated_payment_cents>0 or allocated_deposit_cents>0))
     or exists(select from public.stripe_webhook_events where rental_id=r.id)
     or exists(select from public.rentals where deposit_source_rental_id=r.id or deposit_transferred_to_rental_id=r.id)
  then raise exception 'This rental has a payment or deposit record. Only unused rentals without collected funds can be deleted.'; end if;
  if exists(select from public.rental_return_inspections where rental_id=r.id)
     or exists(select from public.rental_vehicle_assignments where rental_id=r.id and (starting_mileage is not null or ending_mileage is not null))
     or exists(select from public.rental_extension_requests where replacement_rental_id=r.id)
     or exists(select from public.ticket_cases where rental_id=r.id)
     or exists(select from public.tollspot_transactions where rental_id=r.id)
     or exists(select from public.vehicle_reports where rental_id=r.id)
  then raise exception 'This rental has trip, incident, or linked rental activity and cannot be deleted as unused.'; end if;
  if exists(select from storage.objects where bucket_id='rental-inspections' and name like r.id::text||'/%')
     or exists(select from public.rental_documents d join storage.objects o on o.bucket_id='rental-documents' and o.name=d.file_path where d.rental_id=r.id)
     or exists(select from public.rental_photos where rental_id=r.id)
  then raise exception 'Remove the attached files from this rental before deleting it.'; end if;
  if p_confirm is null then return 'delete'; end if;
  if p_confirm <> 'delete' then raise exception 'Confirm permanent deletion to continue.'; end if;

  delete from public.external_payment_allocations a using public.external_payment_receipts e
    where a.receipt_id=e.id and e.rental_id=r.id and e.status='cancelled';
  delete from public.customer_credit_applications a using public.external_payment_receipts e
    where a.receipt_id=e.id and e.rental_id=r.id and e.status='cancelled';
  delete from public.external_payment_cancellations where rental_id=r.id;
  delete from public.external_payment_receipts where rental_id=r.id and status='cancelled';
  delete from public.email_delivery_events d using public.email_outbox o where d.outbox_id=o.id and o.rental_id=r.id;
  delete from public.rental_messages where rental_id=r.id;
  delete from public.admin_customer_messages where rental_id=r.id;
  delete from public.rental_pricing_periods where rental_id=r.id;
  delete from public.merchant_booking_details where rental_id=r.id;
  update public.pending_bookings set status='expired', expires_at=least(expires_at,now())
    where id=r.source_pending_booking_id and status in ('pending','converted');
  -- Rental-owned signatures, audit events, outbox, steps, and initial assignments
  -- cascade with this row. Customer identity and the fleet record are shared.
  delete from public.rentals where id=r.id;
  return 'delete';
end $$;
revoke all on function public.delete_unused_rental(uuid,text) from public,anon;
grant execute on function public.delete_unused_rental(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
