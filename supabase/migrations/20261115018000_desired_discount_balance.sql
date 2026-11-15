begin;
alter function public.admin_preview_manual_rental_discount(uuid,text,numeric) rename to admin_preview_manual_rental_discount_before_target;
revoke all on function public.admin_preview_manual_rental_discount_before_target(uuid,text,numeric) from public,anon,authenticated;
create function public.admin_preview_manual_rental_discount(p_rental_id uuid,p_mode text,p_value numeric) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; preview jsonb; paid numeric; extras numeric; target numeric; base numeric; candidate numeric; discount numeric; actual numeric; offset_cents integer;
begin
 if coalesce(auth.role(),'')<>'service_role' and (auth.uid() is null or not coalesce(is_admin(),false) or not coalesce(rentmect_has_permission('rental.discount'),false)) then raise exception 'Rental discount permission required.'; end if;
 if p_mode<>'target' then return admin_preview_manual_rental_discount_before_target(p_rental_id,p_mode,p_value); end if;
 if p_value is null or p_value<0 or p_value<>round(p_value,2) then raise exception 'Enter a desired balance of zero or more, with at most two decimal places.'; end if;
 select * into strict r from rentals where id=p_rental_id;
 paid:=rentmect_rental_net_paid_amount(r.id);
 select coalesce(sum(greatest(0,round(c.total_amount*100)-coalesce((to_jsonb(c)->>'allocated_payment_cents')::numeric,0)-coalesce((to_jsonb(c)->>'allocated_waiver_cents')::numeric,0)-coalesce((to_jsonb(c)->>'allocated_deposit_cents')::numeric,0)))/100,0) into extras
 from rental_charge_items c where c.rental_id=r.id and c.charge_type not in ('rental_amendment','rental_installment') and c.status not in ('paid','waived','cancelled') and not coalesce(c.included_in_initial_payment,false);
 if p_value>=greatest(0,rentmect_rental_invoice_total(r.id)-paid)+extras then raise exception 'The desired balance must be lower than the current amount due.'; end if;
 target:=p_value-extras+paid;
 base:=case when coalesce(r.manual_discount_amount,0)>0 then coalesce(r.pre_manual_discount_rental_total,r.rental_total+r.manual_discount_amount) else r.rental_total end;
 candidate:=round((target-coalesce(r.security_deposit,0)-coalesce(r.service_fee_total,0)+coalesce(r.taxable_service_fee_total,0))/1.0635-coalesce(r.taxable_service_fee_total,0),2);
 if p_value<extras or candidate<0 then raise exception 'That balance is below the unchanged deposit, fees and additional charges after payments. Only rental charges can be discounted.'; end if;
 for offset_cents in -1..1 loop
  discount:=round(base-candidate-offset_cents/100.0,2);
  if discount<=coalesce(r.manual_discount_amount,0) or discount>base then continue; end if;
  preview:=admin_preview_manual_rental_discount_before_target(r.id,'fixed',discount);
  actual:=greatest(0,(preview->>'new_total')::numeric-paid)+extras;
  if actual=p_value then
   return preview||jsonb_build_object('mode','target','desired_balance_due',p_value,'total_balance_due',actual,'additional_charges_due',extras,'current_balance_due',greatest(0,rentmect_rental_invoice_total(r.id)-paid)+extras);
  end if;
 end loop;
 raise exception 'That exact balance is not possible after tax rounding. Try one cent higher or lower.';
end $$;
revoke all on function public.admin_preview_manual_rental_discount(uuid,text,numeric) from public,anon;
grant execute on function public.admin_preview_manual_rental_discount(uuid,text,numeric) to authenticated,service_role;
commit;
