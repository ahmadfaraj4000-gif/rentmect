# Customer blocking — September 26, 2026

Staff can open Customers → Details → Rental access, enter a reason, and choose
Block customer. This works without a damage case and after a completed rental.
The same section provides Unblock customer. The existing damage-case action
uses the same permission-checked RPC.

Database migration `20260926120000_customer_identity_blocks` adds a private,
persistent identity block list. Email matching ignores case and surrounding
spaces; US phone matching ignores formatting and treats 10-digit and +1 numbers
as the same identity. Existing blocked profiles are backfilled. A blocked
account's old contacts remain blocked when staff correct its contact details.
Deleting an account does not remove its blocks. Explicitly unblocking a profile
removes only blocks originating from that profile.

Database triggers enforce the restriction on auth account creation and contact
changes, customer profile contacts, pending bookings, new rentals, pickup/approval
transitions, and extensions. These guards also cover direct database API writes,
admin bookings, and existing accounts sharing a blocked identifier. Customers
cannot clear their own block; employees require customer.manage permission.
Returns, cancellations, refunds, and collection of existing charges remain
available. Blocking does not automatically cancel reservations, expire existing
Stripe links, or issue refunds. Account login itself remains available. Because
current signup collects email first, a different email cannot be matched to a
blocked phone until that phone is supplied; saving that phone is rejected.

## Verification

- Executable transactional SQL regression covers block/unblock, email case,
  phone formatting, auth phone and metadata phone signup, profile and auth
  contact changes, guest bookings, rentals, extensions, pickup, return/completion,
  cancellation, self-unblock prevention, employee permissions, preservation after
  deletion, and overlapping blocks from independent sources. All passed against
  the linked database; fixtures and migration rehearsal were rolled back.
- Browser checked the actual form and handler extracted into a temporary local
  preview: empty reasons disable blocking; saving displays the reason and Unblock;
  unblocking restores the form. No real customer was blocked during UI testing.
- Configured production build passed. Release gate plus customer tests: 35 passed.
- Full admin suite on Node 25: 197 passed; the existing partial-payment-installments
  test cannot load the absent `20260813213000_admin_partial_payment_installments.sql`.
- Migration deployed and recorded in migration history. Backfill: one already
  blocked profile, two protected identifiers; zero leftover test profiles.
- Admin commit: `88dbdd2`.
- Admin deployment: https://github.com/ahmadfaraj4000-gif/rentmect-admin-portal/actions/runs/36280893269
