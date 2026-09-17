# Deposit refund integrity incident — September 17, 2026

## Root cause

`admin_adjust_external_rental_payment` estimated the deposit portion of an external receipt from the difference between net payments and the current non-deposit invoice. It added that estimate to `rentals.deposit_released_amount` even when its allocation loop released nothing. The receipt ledger and current deposit summary therefore described different things.

`ensure_rental_deposit_allocation` subsequently created a new Stripe-backed deposit without clearing the unrelated historical external-return aggregate. The booking history fallback treated any positive aggregate as a new refund, used the current booking status to label it pending, and used `rentals.updated_at` as the transaction date. An ordinary booking edit therefore moved a historical amount to the top of the ledger as an apparent new refund.

The initial presentation patch prevented that duplicate display but did not repair the inconsistent database summaries. This change addresses the writers, stored summaries, settlement transaction, and both ledger views.

## Evidence and scope

The database-wide audit found two allocation/summary mismatches: historical external-return amounts of $282.04 and $110 alongside intact $300 Stripe allocations with $0 released and no refund ID. Each discrepancy exactly matched retained external-refund records. One other local allocation had a real external-receipt return already represented inside a full receipt; its amount and event timestamp provide an exact attribution for deduplication.

The historical records identify the account that entered an external return. They do not independently establish whether cash or another external transfer actually occurred. Those records, reasons, actors, and amounts are preserved.

## Corrections

- Current released totals are derived from actual deposit allocations, never an estimated receipt portion.
- Allocation updates synchronize the summary. A deferred database constraint prevents committing an inconsistent released total.
- External receipt refunds cannot reduce a Stripe allocation or a carried allocation belonging to another source rental.
- Local receipt returns carry explicit allocation attribution so their deposit portion is not counted twice in either ledger.
- Local deposit release derives the resulting total instead of adding to an already-synchronized total.
- A released/transferred Stripe capture cannot be reused to reconstruct another deposit. Existing captured allocations cannot silently absorb a later local receipt.
- Dedicated refund timestamps are preserved through unrelated edits and webhook replays. Historical dates are backfilled only from recorded release events; unknown dates remain unknown.
- Stripe allocation and booking status settle through one service-only transaction with payment-source validation. Completed refunds cannot regress to pending through an older webhook.
- Allocation returns cannot exceed captured allocation amounts, and a Stripe refund ID cannot be recorded against two allocations.
- Legacy Stripe webhooks without a unique matching allocation fail for reconciliation instead of manufacturing a booking-level refund.
- Booking and Payments views share deposit-refund logic. External returns retain their own timestamp, reason, and account attribution.
- Refund-history regression tests run before every admin portal deployment.

## Data repair

The migration repairs only the two proven stale-summary discrepancies. It leaves both current $300 held deposits and every historical external-payment action intact. Each repair writes `deposit_summary_integrity_repaired`, recording the previous value, corrected value, reason, and `money_moved: false`. It submits no Stripe refunds or charges.

## Validation

- Executable database regressions in `supabase/tests/deposit_refund_integrity.sql` reproduce the original error, test external-versus-Stripe isolation, local attribution, duplicate returns, allocation totals, fixed timestamps, late webhooks, capture reuse, atomic settlement, source matching, restricted access, direct local release, inconsistent writes, and over-release. All fixture changes roll back; there are no payment-provider calls.
- Targeted frontend/backend JavaScript regressions validate the same historical fixture, both ledger views, deduplication, Stripe retries, and transactional settlement calls.
- The full admin suite has one pre-existing failure: a referenced historical migration file is missing from the workspace (`20260813213000_admin_partial_payment_installments.sql`). This is unrelated to the deposit tests.
- A post-deployment read-only audit checks all bookings against their allocation totals.

These checks prevent the identified failure mechanisms. They do not verify physical cash returns or promise the absence of unrelated future defects.

## Deployed verification

- Database migration `20260917210000` applied and recorded; Stripe edge function version 90 is ACTIVE.
- Admin deployment `35272170147` succeeded, including the new refund-history regression gate. The public JavaScript bundle contains the dedicated refund timestamps and external-receipt attribution.
- Post-deployment audit: **91 bookings checked; 0 held-total mismatches; 0 released-total mismatches; 0 over-released allocations; 0 duplicate refund references.**
- Both repaired bookings retain a $300 held deposit, with current allocated released total $0. Their $282.04 and $110 historical external records remain intact, with repair audit events.
- 23 targeted JavaScript tests passed. Full suite: 183 passed, 1 pre-existing missing-migration test failure. Production build passed.
