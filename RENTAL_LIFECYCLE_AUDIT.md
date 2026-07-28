# Rental Lifecycle Audit

Updated: July 24, 2026

## Production state machine

1. **Available**
   - No overlapping rental, admin block, or active website checkout hold.
2. **Website checkout hold**
   - A selected vehicle is blocked immediately for the requested dates.
   - The hold lasts 25 minutes and appears in customer and admin availability.
   - Competing hold/rental creation is serialized with a per-vehicle advisory lock.
3. **Unpaid reservation**
   - Website/customer reservations retain the original 25-minute deadline.
   - Admin-created reservations receive a payment deadline (24 hours by default,
     shortened for near-term pickup).
   - The every-minute lifecycle sweep cancels unpaid expired reservations even
     if a Stripe Checkout session was opened.
4. **Paid reservation**
   - Successful payment is the inventory point of no return.
   - Paid reservations never auto-cancel.
   - The guarded admin cancellation action rejects paid reservations; paid
     cancellations must use a deliberate refund workflow.
5. **Ready for pickup**
   - Phone, identity, approved license and insurance, signed agreement, payment,
     and starting mileage are required before vehicle release.
6. **Active / overdue**
   - The customer chooses one explicit next path: return, extend the same car,
     or exchange cars.
   - Extension/exchange requests do not alter the active schedule until approved
     and paid.
   - Approved continuation holds expire after two unpaid hours and release their
     calendar block automatically.
7. **Return initiated**
   - The customer can report an early or on-time return after actual drop-off.
   - Open extension/exchange requests must be resolved first.
   - The car remains unavailable until admin inspection.
8. **Inspected and completed**
   - Ending mileage, fuel, and condition are mandatory checks.
   - Mileage, inspection, deposit decision, rental completion, and vehicle
     disposition are written atomically.
   - Clean vehicle: available.
   - Damage/incident: maintenance or unavailable; deposit must remain held with
     an explanatory note.

## Blind spots found and corrected

- Website pending bookings previously did not block inventory.
- Opening Stripe previously prevented the 25-minute expiry worker from
  cancelling an abandoned unpaid rental.
- Pending website hold conversion previously occurred across three separate
  requests, leaving race and orphan-rental windows.
- Approved unpaid extensions could hold calendar inventory indefinitely.
- Admin-created unpaid bookings had no durable payment deadline.
- Return completion previously allowed the inspection checklist to be skipped.
- Vehicle availability was changed separately from inspection/deposit writes.
- Stripe payments arriving after cancellation/deadline could revive or strand
  inventory. They are now automatically refunded and audited.
- Customer and admin availability calculations did not include active website
  checkout holds.

## Guardrails

- Database triggers protect every insert/update path, including future imports
  and direct admin writes.
- Advisory transaction locks serialize bookings per vehicle.
- Three-hour turnaround buffers remain enforced.
- A customer-owned legacy hold is temporarily compatible with the already
  deployed portal while still blocking every other customer.
- Every expiry, deadline change, cancellation, trip intent, return, inspection,
  and late-payment refund creates an audit event.

## Live verification completed

- Production migrations applied without errors.
- Stripe webhook hardening deployed.
- Every-minute lifecycle cleanup job reinstalled.
- 2 open unpaid admin bookings preserved and assigned payment deadlines.
- 0 reservations missing a deadline.
- Expiry sweep caused 0 unintended cancellations.
- 31 fleet availability rows returned for 31 vehicles, with 0 duplicates.
- 6 scheduled non-cancelled rentals audited, with 0 overlap conflicts.
- Client production build passed.
- Admin production build passed.

## Release status

- Client portal commit: `28c8a0b`
- Admin portal commit: `3da5034`
- Both GitHub Pages deployment workflows completed successfully.
- `https://login.rentmect.com` and `https://admin.rentmect.com` returned HTTP
  200 with the new production asset hashes.
- The in-app browser was unavailable for an authenticated visual click-through;
  production builds, live API assertions, deployment workflow checks, and HTTP
  smoke checks all passed.
