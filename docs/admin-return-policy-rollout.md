# Admin-confirmed vehicle return policy

Production baselines: site/backend `d3383a7947c4007b13405768e398a54c2f0782d3`, admin `4dbd63a4a24716bed7735ef81cf7fdf6a2784405`, client `61c34c0518294fe6dd7114fb52b5d55b87270798`.
The notification function source was downloaded from production before editing; its newer notification types, routing, and authentication are preserved.

## Rules

- Active, rented, overdue and return-initiated rentals retain possession until admin inspection completes. Scheduled return never releases a vehicle.
- Unstarted reservations use exact start/end times. Maintenance, manual blocks, extension holds and checkout holds still apply.
- Same-rental extensions ignore their own possession lock and recheck other conflicts. Continuation pickup requires the original vehicle returned.
- Swaps require verified odometers and an explicit physical-handover confirmation. Maintenance swaps retain the outgoing maintenance restriction. Returned rentals cannot be swapped.
- Automatic late-fee/day staging is disabled, including legacy retries. Manual charges and approved extensions remain available.
- Paid history and signed agreements are preserved. The new agreement applies to new signatures after both portals deploy.

## Release order

1. Verify the three production commits and live function definitions; run `tools/test-admin-return-policy.py` against an isolated database. Optionally set `RENTMECT_LIVE_FUNCTION_CSV` to the exported live definitions.
2. Retire outstanding automatic late-charge Stripe attempts through the protected admin waiver action. Never simply clear payment identifiers.
3. Apply `20261114030000_admin_return_availability.sql` atomically. This disables staging, removes buffers, enforces possession, updates return templates and accepts both agreement versions during rollout.
4. Apply `20261114031000_retire_automatic_late_balances.sql`. It refuses open payment attempts, audits remaining waivers, preserves payments and cancels unsent collection notices.
5. Deploy the two changed notification/reminder functions, preserving their existing JWT configuration. Deploy site, admin and client from their main checkouts through normal checks.
6. Once both portals serve the new agreement, apply `20261114032000_admin_return_agreement_version.sql`.
7. Verify the live possession predicate, zero automatic staging, no unpaid automatic charges, no positive availability buffers, current templates, and successful production deployments.

## Recovery

A migration error rolls back its transaction. Before application, retain exported live definitions. Do not restore automatic charging or release occupied cars as a rollback shortcut. An application rollback must retain the possession rules and compatible agreement validation; correct a failed reader/writer with a forward migration. Waived amounts retain their original ledger history; do not recreate automatic charges or refund historical payments without a separate approved action.

## Validation

The database suite covers exact reservation boundaries, possession before/after due time, customer-return initiation, admin inspection, maintenance preservation, extension exclusion of its own rental, occupied checkout/swap denial, swap handover/idempotency, partial-payment-preserving cleanup and competing swaps/edits. Admin state tests cover indefinite possession and immediate lateness. Desktop/mobile browser checks retain nine workflow steps and confirm collapsed cards issue no detail requests.
