// Original charge prices remain immutable after a partial receipt.
export function chargeCollectionCents(charge) {
 const total=Math.round(Number(charge.total_amount||0)*100);
 const allocated=charge.allocation_managed ? Number(charge.allocated_payment_cents||0)+Number(charge.allocated_deposit_cents||0)+Number(charge.allocated_waiver_cents||0) : 0;
 if(!Number.isSafeInteger(total)||!Number.isSafeInteger(allocated)||allocated<0||allocated>total)throw new Error('Charge allocations are inconsistent. Refresh before collecting.');
 return total-allocated;
}
