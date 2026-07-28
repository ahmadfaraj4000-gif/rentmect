-- Records the admin's intended collection path without weakening payment gates.
-- Run after admin_manual_booking_payment_hardening.sql.

alter table public.rentals
  add column if not exists admin_payment_collection_preference text not null default 'customer_link'
    check (admin_payment_collection_preference in ('customer_link', 'admin_stripe', 'external', 'later'));

comment on column public.rentals.admin_payment_collection_preference is
  'Admin workflow preference only. It never marks a payment complete or bypasses verification/document/agreement gates.';
