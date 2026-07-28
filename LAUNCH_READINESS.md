# Rent Me CT launch readiness — July 19, 2026

## Current status

- Admin portal production build: passes.
- Client portal production build: passes.
- Audit log database migration and admin UI: implemented locally.
- Deposit policy: enforced as $500 under age 25 and $300 at age 25 or older in
  customer booking, admin booking, database enforcement, and Stripe Checkout.
- Deposit release: implemented as an idempotent partial Stripe refund. Admins
  can trigger it after a rental is completed. Clean completed returns are
  scheduled for automatic refund seven days after completion; a hold/damage
  decision prevents automatic refund.
- Wheelbase availability implementation in `index.html`, `cars.html`, and
  `supabase/functions/wheelbase-availability/index.ts`: not modified by this work.
- Admin email center, booking-confirmation outbox, SendGrid worker, customer
  marketing consent, campaign scheduling, and delivery-event history: implemented locally.
- Admin one-to-one customer email/SMS composer, reusable manual templates,
  Twilio/SendGrid delivery logging, and audit attribution: implemented locally.
- Supabase-only Booking Preview fleet/detail/verification handoff: implemented locally.
  The public `cars.html` Wheelbase booking path remains intact and separate.
- Database-wide real-vehicle overlap/three-hour-turnaround guard, extension
  calendar-block checks, and no-charge fixed test-vehicle completion: implemented locally.
- Server-owned booking-fee snapshots, admin toll/add-on charges, customer payment
  links, extension-payment emails, and exact Stripe ledger validation: implemented locally.

## Must complete before taking live payments

1. In Supabase SQL Editor, run `supabase/admin_audit_and_deposit_controls.sql`.
2. Run `supabase/stripe_identity_verification.sql` after the audit/deposit migration.
3. Deploy the updated `supabase/functions/stripe-web-hook/index.ts`. The live
   endpoint currently responds like the previous function, so the local refund
   and scheduler changes are not live yet.
4. Set Edge Function secrets: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
   `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`,
   `SUPABASE_SERVICE_ROLE_KEY`, and a new high-entropy
   `RENTMECT_DEPOSIT_RELEASE_SECRET`.
5. Run `supabase/renter_address_and_vehicle_use.sql`, enable Maps JavaScript API,
   Places API, and Places API (New), then set `VITE_GOOGLE_MAPS_API_KEY` on the
   client portal deployment. Restrict that browser key to
   `https://login.rentmect.com/*` and only those three APIs.
6. Run `supabase/vehicle_deposits_and_under25_pricing.sql` with the SQL Editor
   query title **Vehicle Deposits and Under-25 Pricing**, then deploy the updated
   client portal, admin portal, and `stripe-web-hook` function together.
7. Enable Stripe Identity in the Stripe Dashboard and complete any required business verification.
8. In Stripe, point the webhook to
   `https://<project-ref>.supabase.co/functions/v1/stripe-web-hook/webhook` and
   subscribe to `checkout.session.completed`, `refund.created`,
   `refund.updated`, `refund.failed`, `identity.verification_session.verified`,
   `identity.verification_session.requires_input`, `identity.verification_session.processing`,
   `identity.verification_session.canceled`, `payment_intent.succeeded`, and
   `payment_intent.payment_failed`.
9. Add Supabase Vault secrets `project_url`, `project_anon_key`, and
   `rentmect_deposit_release_secret`. The last value must exactly match the Edge
   Function secret. Then run `supabase/security_deposit_release_schedule.sql`.
10. Replace the client portal's local/placeholder `VITE_CLIENT_PORTAL_URL` with
   its public HTTPS URL before building the deployment. This controls password
   reset redirects.
11. Set `RENTMECT_CLIENT_PORTAL_URL` on the Stripe Edge Function to the public HTTPS
   client-portal URL so Identity return redirects cannot fall back to localhost.
12. Confirm the deployed Edge Function uses Stripe live keys when ready for real
   charges. The repository cannot inspect hosted Supabase secrets, so live mode
   is not currently confirmed.
13. Run two Stripe test-mode bookings using the same vehicle: one renter age 24
   (vehicle deposit plus the configured adjustment and rental markup) and one
   age 25 (vehicle deposit and standard rental rate). Complete a clean return, test the admin refund button,
   and verify the Stripe refund plus audit record.
14. Run a Stripe Identity test session with a matching test document/selfie and a
   failed/retry session. Confirm pickup stays blocked until status is `verified`.
15. Have counsel review the July 19 Stripe Identity privacy disclosure and define
   an operational non-biometric/manual alternative for customers who cannot or do
   not consent to selfie verification where applicable law requires one.
16. Run `supabase/admin_pushover_notifications.sql`, followed by
   `supabase/vehicle_maintenance_notifications.sql`; deploy `notify-admin-events`
   and set `PUSHOVER_APP_TOKEN`, `PUSHOVER_USER_KEY`, and
   `RENTMECT_ADMIN_PORTAL_URL` as Edge Function secrets. Confirm new-booking,
   document-review, return-due-today, and maintenance-due alerts on the admin phone.
17. Run `supabase/email_automation_and_campaigns.sql`, deploy the `send-emails`
    Edge Function, and set `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`,
    `SENDGRID_FROM_NAME`, `SENDGRID_REPLY_TO_EMAIL`,
    `SENDGRID_MARKETING_UNSUBSCRIBE_GROUP_ID`, `RENTMECT_EMAIL_WORKER_SECRET`,
    and `SENDGRID_EVENT_WEBHOOK_SECRET` as server-only Edge Function secrets.
18. Add the Vault secret `rentmect_email_worker_secret` with the exact same value
    as `RENTMECT_EMAIL_WORKER_SECRET`, then run `supabase/email_worker_schedule.sql`.
    In SendGrid, point the Event Webhook to
    `https://<project-ref>.supabase.co/functions/v1/send-emails/webhook?token=<SENDGRID_EVENT_WEBHOOK_SECRET>`
    and enable delivered, deferred, bounce, dropped, spam-report, and unsubscribe events.
19. Verify the configured SendGrid sender/domain, send an admin test email, complete
    one Stripe test booking, and confirm the booking confirmation progresses from
    queued to sent and then delivered in Admin → Emails → Delivery History.
20. Run `supabase/local_payment_and_extensions.sql`, then
    `supabase/booking_integrity_guards.sql`, and finally
    `supabase/booking_flow_test_payment.sql` in the connected SQL Editor. Run
    `supabase/booking_integrity_audit.sql` afterward; it must report PASS and
    rolls back all test vehicles/rentals automatically.
21. Deploy the client portal and the updated `cars.html`. Confirm the footer
    Booking Preview opens `?preview=fleet`, while a normal public vehicle booking
    still opens Wheelbase checkout.
22. Run `supabase/rental_billing_and_completion.sql`. Then rerun, in order,
    `supabase/local_payment_and_extensions.sql`, `supabase/stripe_payments.sql`,
    and `supabase/booking_flow_test_payment.sql` so their payment functions bind
    to the new charge ledger and extension calendar-hold helper.
23. Deploy the updated `stripe-web-hook` and `notify-admin-events` Edge Functions,
    plus the client and admin portals. Do not replace or remove the existing
    Wheelbase availability/checkout functions used by `cars.html`.
24. Run `supabase/vigorous_booking_audit.sql` in SQL Editor. It must finish with
    PASS. The transaction rolls back its temporary vehicle, rentals, service fees,
    messages, and simulated ledger entries and never calls Stripe, SendGrid,
    Pushover, Twilio, or Wheelbase.
25. In Stripe test mode, repeat one age-24 and one age-25 booking and verify the
    Checkout amount against the SQL audit totals. Test one extension and one
    admin-added toll through Checkout. Then create another toll and use **Charge
    saved card** from Admin → Rentals; verify one successful off-session test card
    and one authentication-required test card falls back to the customer payment
    link without being marked paid. Do not perform these checks with live keys.
26. For the admin-assisted booking workflow, run
    `supabase/admin_booking_procedure_and_customer_retention.sql`,
    `supabase/admin_manual_booking_payment_hardening.sql`, and
    `supabase/customer_checkout_cleanup_hardening.sql`; then run
    `supabase/rental_mileage_workflow.sql` and
    `supabase/admin_procedure_override_lockdown.sql` to disable legacy staff
    procedure overrides. Run
    `supabase/deposit_carryover_and_emergency_exceptions.sql`, then rerun
    `supabase/local_payment_and_extensions.sql`,
    `supabase/vehicle_deposits_and_under25_pricing.sql`, and
    `supabase/stripe_payments.sql`; finally rerun
    `supabase/stripe_identity_verification.sql` and
    `supabase/admin_audit_and_deposit_controls.sql`. This installs the
    deposit-allocation ledger, carries deposits across extensions/switches,
    charges or refunds only the difference, and enables scoped emergency
    release exceptions. Confirm the oldest admin profile is the intended owner
    receiving `emergency_override_authorized = true`; explicitly authorize any
    other owner account and leave ordinary staff false. Deploy
    `admin-manual-booking`, `stripe-web-hook`, and
    `notify-admin-events`, then set
    `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and either
    `TWILIO_MESSAGING_SERVICE_SID` or `TWILIO_PHONE_NUMBER` on that Edge
    Function. Send a test secure checklist by both email and SMS before launch.
26. Run `supabase/admin_customer_communications.sql`, redeploy `send-emails` and
    `send-rental-due-reminders`, and set `RENTMECT_CLIENT_PORTAL_URL` plus
    `RENTMECT_PHONE` on both functions. From Admin → Customers, send one manual
    email and one manual text to controlled test contact details, verify the
    rendered rental dates/vehicle, and confirm rows appear in
    `admin_customer_messages`. This is a live delivery test, so use only contact
    details you control.
27. Run `supabase/manual_booking_payment_preferences.sql`, then redeploy
    `admin-manual-booking` and the admin portal. Create controlled manual
    bookings using each payment plan. Confirm Stripe Checkout and external
    payment remain locked until phone, identity, approved license,
    rental-specific approved insurance, and agreement are complete. Never type
    card data into the admin portal; the on-device option opens Stripe Checkout.
28. Follow `TOLLSPOT_INTEGRATION.md` for the staged Customer API integration.
    The supplied contract requires server-side polling with `X-API-KEY`; it does
    not define webhooks. The credential is stored in Supabase Secrets as
    `TOLLSPOT_API_KEY`; its protected local copy remains only in the ignored
    server environment. The production database migration and `tollspot-sync`
    Edge Function are deployed with scheduled synchronization disabled. The
    production base URL `https://selfserve.tollspot.app/api` was confirmed from
    TollSpot's onboarding email, and the deployed read-only health check
    connected successfully on July 27, 2026. Confirm sandbox availability,
    rate limits, date semantics, and remaining provider-contract questions.
    Rotate the API key because it appeared in a troubleshooting screenshot.
    Do not enable customer-charge creation until the pilot reconciles exactly
    and duplicate, matching, authorization, and rollback tests pass.
29. Deploy the coordinated automated-billing upgrade: apply
    `20260727190000_automated_billing_tolls_discounts.sql`, deploy
    `tollspot-sync` and `stripe-web-hook`, run
    `supabase/tollspot_automatic_schedule.sql`, and publish both portals.
    Re-run the TollSpot reconciliation first. Then confirm deterministic tolls
    create one pending rental charge, ambiguous tolls stay in the exception
    queue, unpaid charges block both deposit-refund paths, discounts change the
    customer and Stripe totals identically, and the Settings automation switch
    schedules or pauses deposit refunds as expected.

## Strongly recommended before public launch

- Configure Supabase Auth site URL and allowed redirect URLs for both portals.
- Create a separate Auth account/profile for every staff member; set each
  approved staff profile role to `admin` and never share an admin login.
- Run the existing `supabase/rentmect_hardening_preflight.sql` against production
  and resolve every reported missing object or policy.
- Add error monitoring and confirm backups/PITR for the production database.
- Optimize the client vehicle PNGs (currently roughly 1.6–1.9 MB each) to improve
  first-load performance on mobile.
- Perform a real-browser mobile and desktop smoke test. The in-app preview browser
  was unavailable during this audit, so only compile/build verification was completed.
