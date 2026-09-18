-- Read-only post-deployment and operational audit.
select jsonb_build_object(
  'rentals_checked',(select count(*) from public.rentals),
  'released_total_mismatches',(select count(*) from public.rentals r where coalesce(r.deposit_released_amount,0)<>
    (select coalesce(sum(a.amount_released),0) from public.rental_deposit_allocations a where a.holder_rental_id=r.id)),
  'held_total_mismatches',(select count(*) from public.rentals r where exists(select 1 from public.rental_deposit_allocations a where a.holder_rental_id=r.id)
    and abs(coalesce(r.deposit_held_amount,0)-(select coalesce(sum(greatest(0,a.amount_held-a.amount_released-a.amount_applied)),0) from public.rental_deposit_allocations a where a.holder_rental_id=r.id))>0.005),
  'over_released_allocations',(select count(*) from public.rental_deposit_allocations where amount_released+amount_applied>amount_held),
  'applied_total_mismatches',(select count(*) from public.rental_deposit_allocations a where a.amount_applied<>(select coalesce(sum(d.amount),0) from public.rental_deposit_charge_applications d where d.allocation_id=a.id)),
  'duplicate_refund_references',(select count(*) from (select refund_id from public.rental_deposit_allocations where refund_id is not null group by refund_id having count(*)>1) d)
) as deposit_integrity;
