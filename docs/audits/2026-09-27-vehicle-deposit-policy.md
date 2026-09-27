# Vehicle deposit policy correction — September 27, 2026

Diana M Ordonez's Audi S3 #001 booking saved a $350 vehicle base but required
and recorded a $300 deposit. The original insert already contained this
difference. Its payment was recorded by staff as Cash App; no independent
Cash App reconciliation was performed.

Production had both the vehicle pricing trigger and the obsolete age-only
trigger. The latter overwrote vehicle-specific pricing with $300/$500.
Four booking creation functions also retained flat deposit calculations.
The configurable age surcharge was $250 at the time of this correction.

## Deployed policy

Migration `20260927220000_vehicle_deposit_source_of_truth.sql` removes the
obsolete trigger and its function. Admin, customer, website conversion, and
internal preview booking creation now use the selected vehicle's deposit.
Creation audit events report the actual saved deposit.

Renters 25+ use the vehicle base; renters under 25 use that base plus exactly
$200. The existing minimum age guard is unchanged. The canonical under-25
calculator implements the fixed addition, and the settings row is constrained
to the same policy so quotes, snapshot metadata, and frontend estimates agree.
Rental markup remains unchanged and editable.

Admin Settings explains the fixed deposit policy and removes the percentage,
disable, and alternate-amount controls. Saving rental markup preserves the
fixed $200 deposit surcharge even if the page has stale settings.

Paid terms, explicit amendment overrides, deposit waivers, carryovers, payment
capture, and refund logic were not rewritten. This correction does not collect
historical shortfalls or retrospectively change existing rental invoices.
Existing underfunded bookings remain a separate review.

## Verification

- Rollback-only SQL ran the actual admin/customer/website/preview creation
  functions for 48 combinations: bases $0/$350/$400/$725.50 and ages 24/25/40.
- Verified public quotes, saved base/applied deposits, age metadata, creation
  audit amounts, subsequent DOB/date repricing, replacement-vehicle previews,
  explicit keep-existing-deposit previews, and rejection of stale surcharge
  settings.
- The same 48 cases passed both before commit with the proposed migration and
  after deployment. Fixtures, queue entries, and audit events rolled back.
- Deployment used a repeatable-read transaction with whole-row fingerprints
  before and after the migration: all 97 rentals and 44 deposit allocations
  unchanged. The rental_payments table was empty. The count increased from the
  earlier audit's 96 as normal activity continued before deployment.
- Production #001: $350 age 25+, $550 under 25; legacy trigger absent.
- Diana's original $300 rental deposit remains unchanged.
- 34 admin policy/payment/refund/refresh regression tests passed on Node 22,
  including rendering the actual settings form and exercising its save handler
  with stale values. Node 20 initially failed an existing WebSocket-dependent
  test; Node 22 matches the deployment workflow and passes.
- Migration recorded in the production migration registry.
- Admin commit: a8eb146. Deployment succeeded; the public admin JavaScript
  bundle contains the fixed $200 policy and omits the removed adjustment button.
- Deployment: https://github.com/ahmadfaraj4000-gif/rentmect-admin-portal/actions/runs/36354099408

No charge or refund was submitted. Apply the new migration; do not rerun old
bootstrap SQL to deploy this correction.
