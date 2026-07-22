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
- Supabase-only Booking Preview fleet/detail/verification handoff: implemented locally.
  The public `cars.html` Wheelbase booking path remains intact and separate.
- Database-wide real-vehicle overlap/three-hour-turnaround guard, extension
  calendar-block checks, and no-charge fixed test-vehicle completion: implemented locally.

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
   and `identity.verification_session.canceled`.
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
