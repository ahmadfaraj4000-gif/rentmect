begin;
create function public.remove_unused_rental(p_rental_id uuid,p_confirm text default null) returns text
language plpgsql security definer set search_path=pg_catalog,public as $$
declare r public.rentals; fk record; linked boolean; action text:='delete'; protected boolean;
begin
  if public.rental_operations_staff_name() is null then raise exception 'Rental operations access required.' using errcode='42501'; end if;
  select * into strict r from public.rentals where id=p_rental_id for update;
  if r.status not in ('pending','documents_needed','document_review','approved','ready_for_pickup','cancelled')
    or r.starting_mileage is not null or r.inspection_completed_at is not null then
    raise exception 'Only a never-picked-up rental can be removed here.'; end if;
  protected:=coalesce(r.payment_status,'pending') not in ('pending','unpaid','not_due','cancelled')
    or r.paid_at is not null or coalesce(r.payment_amount_cents,0)<>0 or coalesce(r.deposit_held_amount,0)<>0
    or r.stripe_checkout_session_id is not null or r.stripe_payment_intent_id is not null
    or r.checkout_creation_token is not null or r.stripe_deposit_intent_id is not null
    or exists(select from public.external_payment_receipts where rental_id=r.id and status='pending')
    or exists(select from public.rental_charge_items where rental_id=r.id and (status='checkout_open' or stripe_checkout_session_id is not null));
  if protected then raise exception 'Resolve payment activity using the cancellation or refund workflow first.'; end if;

  if r.agreement_signed or r.agreement_signed_at is not null or r.agreement_snapshot is not null
     or exists(select from public.rental_audit_events where rental_id=r.id and event_type not in ('rental_created','website_hold_converted'))
     or exists(select from public.rental_vehicle_assignments where rental_id=r.id and (source<>'initial' or starting_mileage is not null or ending_mileage is not null))
     or exists(select from storage.objects where bucket_id='rental-inspections' and split_part(name,'/',1)=r.id::text)
  then action:='archive'; end if;
  -- Discover referencing tables, including future integrations. Any history defaults to archive.
  if action='delete' then
    for fk in select x.conrelid::regclass as tbl,a.attname from pg_constraint x
      join pg_attribute a on a.attrelid=x.conrelid and a.attnum=any(x.conkey)
      where x.contype='f' and x.confrelid='public.rentals'::regclass
      and x.conrelid not in ('public.rental_audit_events'::regclass,'public.rental_vehicle_assignments'::regclass)
      and x.conrelid::regclass::text not in ('rental_closed_tab_entries','public.rental_closed_tab_entries')
    loop
      execute format('select exists(select from %s where %I=$1)',fk.tbl,fk.attname) into linked using r.id;
      if linked then action:='archive'; exit; end if;
    end loop;
  end if;
  if p_confirm is null then return action; end if;
  if p_confirm<>action then raise exception 'Rental activity changed. Review the action again.'; end if;
  if r.source_pending_booking_id is not null then
    update public.pending_bookings set status='expired',expires_at=least(expires_at,now())
    where id=r.source_pending_booking_id and status in ('pending','converted'); end if;
  if action='delete' then
    delete from public.rentals where id=r.id;
  else
    update public.rentals set status='cancelled',cancelled_at=coalesce(cancelled_at,now()),cancelled_by=auth.uid(),
      cancellation_reason='Incomplete rental archived by rental operations',payment_due_at=null,checkout_expires_at=null
    where id=r.id and status<>'cancelled';
  end if;
  return action;
end $$;
revoke all on function public.remove_unused_rental(uuid,text) from public,anon;
grant execute on function public.remove_unused_rental(uuid,text) to authenticated;
commit;
