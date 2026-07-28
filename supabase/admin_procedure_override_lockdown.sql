-- Disable legacy staff bypasses. Admin-assisted bookings must satisfy the same
-- customer verification, document, agreement, and payment rules as web bookings.

revoke all on function public.admin_override_rental_ready_for_pickup(uuid, text[]) from public;
revoke execute on function public.admin_override_rental_ready_for_pickup(uuid, text[]) from authenticated;

-- The current admin_mark_rental_active definition in rental_mileage_workflow.sql
-- rejects p_override_missing_requirements = true and independently validates
-- verified phone, verified identity, approved documents, agreement, and payment.
