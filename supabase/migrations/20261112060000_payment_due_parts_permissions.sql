begin;
create or replace function public.rentmect_payment_due_parts(p_rental_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare r rentals%rowtype; total integer; funded integer; deposit_due integer;
begin
 -- Only this checked entry point may call the private accounting helpers.
 if coalesce(auth.role(),'') <> 'service_role' and
   (auth.uid() is null or not coalesce(is_admin(),false) or not
     coalesce(rentmect_has_permission('payment.collect') or rentmect_has_permission('charge.manage') or rentmect_has_permission('tab.payments'),false)) then
  raise exception 'Payment access required.';
 end if;
 select * into strict r from rentals where id=p_rental_id;
 total:=round(greatest(0,rentmect_rental_invoice_total(r.id)-rentmect_rental_net_paid_amount(r.id))*100)::integer;
 select round(coalesce(sum(amount_held-external_receipt_refunded_amount),0)*100)::integer into funded
 from rental_deposit_allocations where holder_rental_id=r.id;
 if not exists(select 1 from rental_deposit_allocations where holder_rental_id=r.id)
   and r.deposit_status in ('held','adjustment_refund_due','release_pending','released','transferred','waived') then
  funded:=round(coalesce(r.security_deposit,0)*100)::integer;
 end if;
 deposit_due:=case when r.status in ('completed','cancelled') or r.deposit_status in ('released','transferred','waived') then 0
 else least(total,greatest(0,round(coalesce(r.security_deposit,0)*100)::integer-funded)) end;
 return jsonb_build_object('rentalDueCents',total-deposit_due,'depositDueCents',deposit_due,'bookingDueCents',total);
end $$;
revoke all on function public.rentmect_payment_due_parts(uuid) from public,anon;
grant execute on function public.rentmect_payment_due_parts(uuid) to authenticated,service_role;

commit;
