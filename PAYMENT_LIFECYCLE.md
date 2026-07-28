# Rent Me CT payment lifecycle

## The simple operating rule

Every dollar belongs to a rental. The rental shows the original booking
payment, refundable deposit, extensions, add-ons, tolls, late fees, damage,
cleaning, other incurred charges, payments, waivers, and refunds.

An unpaid post-booking charge locks the deposit refund. The admin can use
**Charge customer**, send the secure payment link, or waive the charge. When
the balance is clear, **Refund Deposit** becomes available. Automatic deposit
release follows the same server-enforced rule and cannot bypass a balance due.

## 1. Quote and age rules

- Renters must be at least 21. The database rejects an under-21 rental even if
  a browser or admin client is modified.
- Every vehicle has its own base daily rate and refundable base deposit.
- Age 25 or older: the selected vehicle's deposit and standard rental rate
  apply.
- Age 21–24: the Settings > Pricing & Billing under-25 deposit adjustment and
  rental markup apply on top of the selected vehicle's base terms.
- Current fleet deposits may differ by vehicle. The supplied configuration
  uses $300, $400, and $500 base deposits; the under-25 adjustment is applied
  to that vehicle-specific amount.
- Active booking fees/add-ons that are configured as initial service fees are
  snapshotted onto the rental.
- Connecticut tax is calculated from the taxable rental price and taxable
  booking fees.

The exact quoted total is:

```text
rental price
+ age markup, when applicable
- valid promotion discount
+ booking fees
+ Connecticut tax
+ refundable security deposit
= amount due at booking
```

A discount reduces the rental price and the tax calculated from that price. It
does not reduce the refundable deposit.

## 2. Reservation and payment prerequisites

Creating a customer reservation locks the selected vehicle for the configured
checkout window. Before Stripe payment can open, the customer must complete:

1. saved contact details and verified phone;
2. Stripe Identity verification;
3. driver-license upload;
4. rental-specific insurance upload;
5. signed rental agreement.

An admin-created booking uses the same checklist. The admin can send the
customer one secure completion link by email and text. The admin cannot mark
identity verification or the customer's signature complete.

## 3. Promotion and discount codes

In Settings > Pricing & Billing, the admin creates a percentage or fixed-dollar
discount code. **Generate & Copy** creates a code and copies it. Every saved
code also has a one-click **Copy** action.

In Settings > Marketing, the admin chooses a saved active discount code for a
popup/banner campaign. A promotion cannot publish a made-up or paused code.

The customer pastes the code before opening Stripe. The server validates the
start date, expiration date, usage limit, and active state, snapshots the
discount on the rental, recalculates tax and the total, and reserves one use.
If an unpaid rental is cancelled, the reserved use is returned.

Stripe always reads the snapshotted database total. If an earlier Stripe
Checkout session exists at the old price, it is expired and replaced instead
of being reused at the wrong amount.

## 4. Initial Stripe payment and deposit

Stripe Checkout collects the rental, initial booking fees, tax, and security
deposit in one card payment. The security deposit is captured money, not only a
temporary card authorization. It is tracked separately in the rental's deposit
allocation ledger so it can later be refunded accurately.

Stripe also saves the payment method for authorized post-rental charges. The
admin portal never receives or stores raw card details.

For an approved external/local payment, an admin records the payment only after
cash, terminal, bank, or other outside funds have actually cleared. The system
then records the rental payment and a locally held deposit allocation.

## 5. Extensions and vehicle switches

- A same-vehicle extension charges the approved extension rental amount and
  tax. It does not charge a second deposit.
- A vehicle switch carries the existing deposit allocation to the continuation
  rental.
- If the replacement vehicle requires a larger deposit, Stripe charges only
  the increase.
- If it requires a smaller deposit, the difference is not refunded until the
  original vehicle passes its return inspection.

## 6. Add-ons and incurred charges

Tolls, late fees, excess mileage, cleaning, damage, fuel, and other add-ons are
`rental_charge_items`. Each item contains its amount, tax, total, source,
payment state, and rental/customer relationship.

Every item appears under **Rental Manager > Rental charges**. The panel shows:

- total still due before deposit return;
- additional charges already paid;
- whether the deposit refund is locked or clear;
- **Charge customer** for the saved card;
- **Send payment link** as the secure fallback;
- **Waive** for an authorized business decision.

The same items and exact totals appear in the customer portal.

## 7. TollSpot

All real fleet vehicles are TollSpot-enabled. The internal checkout test
vehicle is excluded. The scheduled workflow:

1. reconciles Rent Me CT vehicles, plates, and assignments with TollSpot;
2. fetches recent toll transactions every 30 minutes;
3. deduplicates each provider transaction by TollSpot ID;
4. matches the TollSpot vehicle or historical plate assignment;
5. matches the occurrence time to exactly one rental;
6. creates the pending customer toll charge automatically;
7. emails the customer and exposes the charge in both portals.

Repeated polling cannot create a duplicate charge. Parking, violations,
missing mappings, no matching rental, and multiple matching rentals stay in
the **Toll Exceptions** queue because they are not safe to assign
automatically. Those are the only cases that require admin reconciliation.

The customer is not charged automatically merely because TollSpot reported a
toll. The charge is added automatically to the rental; the admin has the
one-click saved-card action, and the customer has the secure payment action.

## 8. Return and deposit release

The return workflow records ending mileage, fuel, condition, damage, vehicle
disposition, and the deposit decision.

For a clean return:

- the rental becomes completed;
- the deposit remains held during the configured post-return delay so TollSpot
  and other incurred charges can arrive;
- any unpaid rental charge blocks manual and automatic refund attempts;
- after the balance is paid or waived, the admin can click **Refund Deposit**;
- if automatic release is enabled, the scheduled Stripe worker refunds it
  after the configured delay without admin work.

For a damage/incident return, the inspection holds the deposit and no automatic
refund is scheduled.

Stripe deposit refunds are idempotent and allocation-based. A retry cannot
refund the same deposit allocation twice. External deposits must be returned
through the original outside method, then the admin records **Refund External
Deposit**. That path also refuses to complete while rental charges remain due.

The card issuer controls when a Stripe refund appears on the customer's
statement after Stripe accepts it.

## 9. Admin's shortest path

Normal rentals should require these payment actions only:

1. Review the rental's procedure checklist.
2. Let the customer pay through Stripe (or record a genuinely cleared external
   payment).
3. Confirm pickup.
4. Confirm return and inspection.
5. If a charge is due, click **Charge customer** or send the link.
6. Click **Refund Deposit**, or let Billing Automation release it.

The Tolls page is an exception console, not a daily data-entry job.

## Deployment order

1. Apply
   `supabase/migrations/20260727190000_automated_billing_tolls_discounts.sql`.
2. Deploy `stripe-web-hook` and `tollspot-sync`.
3. Store the three Vault secrets documented in
   `supabase/tollspot_automatic_schedule.sql`, then run that schedule file.
4. Publish both portal builds together.
5. In Stripe test mode, verify one age-21–24 booking, one age-25+ booking, one
   percentage discount, one fixed discount, one automatic toll, one ambiguous
   toll exception, one saved-card charge, one customer-link charge, and one
   blocked-then-successful deposit refund.
