# Rent Me CT Release Runbook

Last updated: July 19, 2026 (America/New_York)

## Release objective

Launch the public Rent Me CT website while keeping the existing Wheelbase availability and Wheelbase checkout path operational. Test the new Supabase-powered passwordless customer flow in parallel through the discreet **Booking Preview** footer link. Do not replace Wheelbase as the public source of availability until the custom flow passes the acceptance checklist in this document.

There are two separate releases:

1. **Hybrid launch:** public website and Wheelbase continue operating; admin/client portals and Booking Preview are deployed for controlled testing.
2. **Custom-booking cutover:** public vehicle details, availability, and booking buttons move from Wheelbase to the Supabase system only after reconciliation and end-to-end approval.

## Current verified workspace status

- [x] Public website remains connected to Wheelbase availability.
- [x] Public vehicle reserve actions remain connected to Wheelbase checkout.
- [x] `Booking Preview` exists only as a separate footer testing gateway.
- [x] Client portal production build passes.
- [x] Admin portal production build passes.
- [x] Full `npm run perf:check` passes.
- [x] Public fleet images were converted/compressed to WebP.
- [x] Admin vehicle uploads are resized, compressed, and converted to WebP.
- [x] Passwordless email OTP account creation is implemented in the client portal.
- [x] Fifteen-minute database-backed Booking Preview countdown is implemented.
- [x] Admin calendar reads the same `rentals` records created by the client portal.
- [x] Admin calendar uses Realtime updates with a 15-second polling fallback.
- [x] Stripe payment webhook records successful payment on the same rental row.
- [x] Audit-log database support and admin Audit Log UI are implemented locally.
- [x] Deposit calculation is $500 for customers under 25 and $300 for customers age 25 or older.
- [x] Manual security-deposit refund action is available from the Admin Portal Rental Manager as **Refund Deposit Now**.
- [x] Clean completed rentals can be scheduled for automatic deposit refund after seven days.
- [x] Stripe Identity workflow and server-side payment prerequisites are implemented locally.
- [x] Admin-managed site banners/popups, placement, coupon action, and automatic date cutoff are implemented locally.
- [x] Internal `Booking Flow Test Vehicle` and automatic Booking Preview assignment are implemented locally.
- [x] Test vehicle is excluded from normal client vehicle choices and has no public photo.
- [x] Test-vehicle Stripe checkout is blocked when the Edge Function uses a live Stripe key.

Passing a build proves compilation, not that migrations, hosted functions, secrets, DNS, Auth, Stripe, Twilio, or production deployments are configured correctly.

## Wheelbase protection boundary

### Keep unchanged during the hybrid release

- The Wheelbase SDK and rental IDs in `cars.html`.
- `WHEELBASE_AVAILABILITY_PROXY_URL` and its request/response handling.
- `supabase/functions/wheelbase-availability/index.ts`.
- Existing public vehicle-card availability behavior.
- Existing public Reserve buttons and Wheelbase checkout functions.

### Parallel custom path

```text
cars.html footer Booking Preview
            |
            v
Supabase pending booking + 25-minute deadline
            |
            v
login.rentmect.com passwordless OTP
            |
            v
Contact -> phone -> dates/test vehicle -> Stripe Identity
-> license -> insurance -> agreement -> Stripe payment
            |
            v
Same rentals row shown in the admin calendar
```

The public Wheelbase path and the custom Booking Preview path are intentionally separate. A failure in Booking Preview must not change Wheelbase availability or stop a customer from using the existing Reserve buttons.

Known unchanged integrity references from the latest workspace check:

- `index.html`: `67a7927e23ec8f066e2b6e8fcf1ca814c5505df473b3e32282d74c0048a13d7b`
- `supabase/functions/wheelbase-availability/index.ts`: `c2b75c8c63957c0da0c412181d116b6f1d97670cd91e275af73a4d935721f279`

`cars.html` has intentionally changed for optimized images, promotions, and the isolated Booking Preview handoff. Its Wheelbase SDK/proxy/reserve path must be regression-tested before every deployment.

## Completed functionality

### Public website

- Responsive public landing and fleet pages.
- Wheelbase availability and checkout remain active.
- Fleet images optimized for faster loading.
- Promotion banner and popup support.
- Promotion visibility controlled by database start/end timestamps.
- Coupon-copy action preserved.
- Footer Booking Preview handoff carries selected dates and times to the client portal.
- Booking Preview no longer requires clicking a public car or entering Wheelbase checkout.

### Client portal

- Passwordless `signInWithOtp` with automatic first-time account creation.
- Numeric email OTP verification UI.
- Pending booking ID survives the handoff through Supabase.
- Required guided flow:
  1. Customer details and phone verification.
  2. Dates/times and assigned/selected vehicle.
  3. Stripe Identity verification.
  4. Driver-license upload.
  5. Insurance upload.
  6. Rental agreement and signature.
  7. Stripe payment.
- Server refuses payment unless required verification, documents, and agreement are complete.
- Fifteen-minute countdown is stored on the server and does not reset on refresh.
- Expired unpaid holds are cancelled and released by a scheduled database cleanup.
- Customer rental history, messages, extensions, return workflow, and document replacement UI.
- Public vehicle assets resolve from `https://rentmect.com/assets` when the portal is deployed at `https://login.rentmect.com`.

### Admin portal

- Dashboard and operations queue.
- Shared source-of-truth fleet calendar.
- Manual bookings for existing or new customers.
- Rental status and return management.
- Customer records and notes.
- Vehicle status, pricing, images, and availability blocks.
- Document review and customer messaging.
- Discount codes, service fees, banners, and popups in Settings.
- Audit Log tab for staff activity.
- Manual Stripe security-deposit refund control.
- Extension approval/payment workflows.
- Realtime calendar updates plus 15-second fallback refresh.

### Database and integrations

- Production RLS policies and customer/admin ownership boundaries.
- Locked rental creation with overlap checks and three-hour turnaround rules.
- Admin calendar blocks included in client availability.
- Stripe Checkout payment recording is webhook/idempotency based.
- Stripe Identity status synchronization.
- Deposit refund scheduling and audit events.
- Rental return reminders and admin paid-rental SMS alert database support.
- Vehicle image storage policies.
- Promotion storage and public active-promotion read policy.

## Tomorrow: unblock Booking Preview testing first

Complete these in order before spending time on visual changes.

### 1. Connect Resend to Supabase Auth

- [ ] Verify the sending domain in Resend and finish all required DNS records.
- [ ] Create a restricted Resend API key for Supabase Auth.
- [ ] In Supabase, open **Authentication -> Emails -> SMTP Settings**.
- [ ] Configure:

```text
Sender email: bookings@rentmect.com (or another address on the verified domain)
Sender name: Rent Me CT
Host: smtp.resend.com
Port: 465
Username: resend
Password: Resend API key
```

- [ ] Keep the **Magic link or OTP** email template code-only using `{{ .Token }}`.
- [ ] Change its subject to `Your Rent Me CT sign-in code`.
- [ ] Set a reasonable Auth email/OTP rate limit for testing and expected launch traffic.
- [ ] Send one new OTP after SMTP is saved and confirm it arrives from the Rent Me CT domain.
- [ ] Never put the Resend API key in either Vite frontend or public JavaScript.

Supabase's built-in sender is limited and is not suitable for production. The current `email rate limit exceeded` message is expected until the default allowance resets or custom SMTP is enabled.

### 2. Verify Auth URLs

- [ ] Set Supabase Auth Site URL to `https://login.rentmect.com`.
- [ ] Add `https://login.rentmect.com/**` to allowed redirect URLs.
- [ ] Add exact local development URLs only if they are still needed for testing.
- [ ] Confirm OTP sign-in works in Safari, Chrome, iPhone Safari, and Android Chrome.
- [ ] Confirm first-time OTP creates one account and returning OTP reuses it.
- [ ] Confirm an OTP cannot attach a pending booking already claimed by a different user.

### 3. Verify phone OTP functions

The client calls `send-phone-code` and `check-phone-code`. The original `send-phone-code`
source is version-controlled; recover the deployed `check-phone-code` source before changing it.

- [ ] Confirm both functions currently exist in the hosted Supabase project.
- [ ] Confirm they use Twilio Verify or an equivalent server-side verification mechanism.
- [ ] Confirm their secrets are configured and no Twilio credential reaches the browser.
- [ ] Test correct, incorrect, expired, and repeatedly requested phone codes.
- [ ] Recover the deployed `check-phone-code` source into this repository before launch.
- [ ] Add rate limiting and abuse controls if the hosted functions do not already enforce them.

This is a blocking production issue if the hosted functions are missing or cannot be reproduced from version-controlled source.

## Supabase database deployment

Do not blindly rerun every SQL file against production. First run the preflight and compare deployed schema/functions/policies with the workspace. Several migrations replace the same functions, so order matters.

### Preflight

- [ ] Run `supabase/rentmect_hardening_preflight.sql` and save the results.
- [ ] Back up the database before applying launch migrations.
- [ ] Confirm whether each migration below has already been applied.
- [ ] Apply missing migrations in a staging project first.

### Recommended dependency order for a clean/staging database

1. `supabase/rentmect_hardening.sql`
2. `supabase/production_rls_policies.sql`
3. `supabase/profile_security_hardening.sql`
4. `supabase/renter_address_and_vehicle_use.sql`
5. `supabase/rental_workflow_security_hardening.sql`
6. `supabase/customer_surface_security_hardening.sql`
7. `supabase/admin_pricing_settings.sql`
8. `supabase/local_payment_and_extensions.sql`
9. `supabase/fix_vehicle_availability_buffer_rules.sql`
10. `supabase/rental_mileage_workflow.sql`
11. `supabase/admin_manual_booking.sql`
12. `supabase/admin_audit_and_deposit_controls.sql`
13. `supabase/stripe_identity_verification.sql`
14. `supabase/stripe_payments.sql`
15. `supabase/customer_age_deposit_and_calendar_realtime.sql`
16. `supabase/client_portal_calendar_source_of_truth.sql`
17. `supabase/passwordless_checkout_hold.sql`
18. `supabase/extend_checkout_hold_to_25_minutes.sql`
19. `supabase/site_promotions.sql`
20. `supabase/rental_documents_table_policies.sql`
21. `supabase/rental_documents_storage_policies.sql`
22. `supabase/vehicle_images_storage.sql`
23. `supabase/rental_due_sms_reminders.sql`
24. `supabase/booking_flow_test_vehicle.sql`
25. `supabase/vehicle_deposits_and_under25_pricing.sql`
26. Fleet seed files only if the matching production vehicle IDs have been verified.
27. Cron schedule files only after their secrets/functions are ready.

`client_portal_calendar_source_of_truth.sql` must remain the final active definition of `create_rental_with_lock` among the availability migrations. `passwordless_checkout_hold.sql` then adds the hold functions without replacing that rental-lock function. The vehicle/under-25 pricing migration must run after the legacy audit migration so its per-vehicle pricing trigger replaces the old global $300/$500 trigger.

### New Booking Preview objects that must be confirmed

- [ ] `pending_bookings.expires_at`
- [ ] `rentals.checkout_expires_at`
- [ ] `create_website_pending_booking`
- [ ] `get_website_pending_booking`
- [ ] `claim_customer_pending_booking`
- [ ] `attach_customer_checkout_hold`
- [ ] `convert_customer_pending_booking`
- [ ] `expire_customer_checkout_hold`
- [ ] `expire_stale_customer_checkout_holds`
- [ ] `rentmect-expire-checkout-holds` pg_cron job
- [ ] Fixed test vehicle ID `00000000-0000-4000-8000-000000000015`

## Edge Functions and secrets

### Functions present in this workspace

- `wheelbase-availability` — existing public Wheelbase availability proxy; preserve behavior.
- `stripe-web-hook` — Checkout, Identity, webhook recording, deposit refund, and scheduled release actions.
- `admin-manual-booking` — secure admin-created customer/rental workflow.
- `send-rental-due-reminders` — rental reminders and admin SMS alerts.

### Deploy/verify

- [ ] Deploy the updated `stripe-web-hook` after its database migrations.
- [ ] Deploy/verify `admin-manual-booking`.
- [ ] Deploy/verify `send-rental-due-reminders`.
- [ ] Verify the existing `wheelbase-availability` function but do not replace it casually.
- [ ] Recover and version `send-phone-code` and `check-phone-code`.

### Required server-side secrets

- [ ] `SUPABASE_URL`
- [ ] `SUPABASE_SERVICE_ROLE_KEY`
- [ ] `STRIPE_SECRET_KEY`
- [ ] `STRIPE_WEBHOOK_SECRET`
- [ ] `RENTMECT_CLIENT_PORTAL_URL=https://login.rentmect.com`
- [ ] `RENTMECT_DEPOSIT_RELEASE_SECRET`
- [ ] Twilio account/Verify credentials required by the deployed phone/reminder functions.
- [ ] Resend credentials in Supabase SMTP settings, not frontend environment variables.

Never expose service-role, Stripe secret, webhook, Resend, or Twilio secrets through `VITE_*`, `cars.html`, `index.html`, or another browser bundle.

## Stripe readiness

### Test mode

- [ ] Enable Stripe Identity for the account.
- [ ] Deploy the Edge Function with Stripe test keys.
- [ ] Create the webhook endpoint:
  `https://<project-ref>.supabase.co/functions/v1/stripe-web-hook/webhook`
- [ ] Subscribe to:
  - `checkout.session.completed`
  - `refund.created`
  - `refund.updated`
  - `refund.failed`
  - `identity.verification_session.verified`
  - `identity.verification_session.requires_input`
  - `identity.verification_session.processing`
  - `identity.verification_session.canceled`
- [ ] Put the webhook signing secret in the Edge Function secrets.
- [ ] Test a 24-year-old customer and confirm a $500 deposit.
- [ ] Test a 25-year-old customer and confirm a $300 deposit.
- [ ] Confirm an unverified identity cannot reach payment.
- [ ] Confirm missing license, insurance, phone verification, or agreement blocks payment on the server.
- [ ] Complete payment and confirm the rental becomes `paid` in the admin calendar.
- [ ] Complete a clean return and manually refund the deposit from Rental Manager.
- [ ] Confirm Stripe refund status and audit log.
- [ ] Test the seven-day automatic refund schedule using a controlled shortened due date in staging.
- [ ] Confirm damage/hold cases do not auto-refund.

The internal Booking Flow Test Vehicle can open Stripe only when the configured secret starts with `sk_test_`. This is an intentional safety guard.

### Live mode

- [ ] Finish Stripe business verification.
- [ ] Replace test secrets with live secrets only after all test cases pass.
- [ ] Create/verify the live webhook separately from the test webhook.
- [ ] Perform one controlled low-risk live booking with an authorized cardholder.
- [ ] Verify receipt, webhook, calendar, deposit state, and refund behavior.

## Scheduled jobs

- [ ] Store Vault secrets required by `security_deposit_release_schedule.sql`:
  - `project_url`
  - `project_anon_key`
  - `rentmect_deposit_release_secret`
- [ ] Ensure the Vault deposit secret exactly matches the Edge Function secret.
- [ ] Run `supabase/security_deposit_release_schedule.sql` only after the Stripe function is deployed.
- [ ] Run `supabase/rental_due_sms_reminder_schedule.sql` only after reminder functions and Twilio are verified.
- [ ] Confirm `rentmect-expire-checkout-holds` runs every minute.
- [ ] Inspect pg_cron history for failed jobs.

## Portal deployments and domains

### Client portal

- [ ] Deploy `rentmect-client-portal/dist` to `https://login.rentmect.com`.
- [ ] Confirm the host serves the SPA from `/` and supports direct navigation/refresh.
- [ ] Configure production `VITE_SUPABASE_URL` and publishable/anon key.
- [ ] Configure `VITE_PUBLIC_FLEET_ASSET_BASE_URL=https://rentmect.com/assets` if the default is not appropriate.
- [ ] Confirm HTTPS and DNS.

### Admin portal

- [ ] Decide and configure the production admin hostname.
- [ ] Deploy `rentmect-admin-portal/dist`.
- [ ] Configure production Supabase publishable/anon key and address variables.
- [ ] Restrict access by authenticated profile role, not by `VITE_ADMIN_EMAIL` alone.
- [ ] Create an individual Auth account for every employee.
- [ ] Set only approved staff profiles to `role = 'admin'`.
- [ ] Never share an admin account.
- [ ] Confirm audit logs display the acting user ID/email and detailed action.

### Public website

- [ ] Deploy public static files only after staging smoke tests.
- [ ] Confirm all asset paths and cache headers.
- [ ] Confirm promotion banner and popup appearance/coupon behavior.
- [ ] Confirm promotions disappear automatically after their configured end timestamp.
- [ ] Confirm Booking Preview opens `https://login.rentmect.com/?booking=<id>&preview=1`.
- [ ] Confirm every normal Reserve action still opens Wheelbase.

## Required end-to-end acceptance test

Use a new email address and Stripe test mode.

- [ ] Choose valid pickup/return dates and times in `cars.html`.
- [ ] Click footer Booking Preview without choosing a public car.
- [ ] Confirm `Booking Flow Test Vehicle` is assigned automatically.
- [ ] Confirm selected dates/times carry into the client portal.
- [ ] Confirm the countdown starts near 15:00 and does not reset after refresh.
- [ ] Request one numeric email OTP and sign in.
- [ ] Confirm a first-time Auth account/profile is created automatically.
- [ ] Save full legal name, date of birth, phone, and address.
- [ ] Verify phone by SMS.
- [ ] Create the rental and confirm it immediately appears as an unpaid calendar booking.
- [ ] Complete Stripe Identity.
- [ ] Upload driver license and insurance.
- [ ] Sign the agreement.
- [ ] Pay using a Stripe test card.
- [ ] Confirm Stripe webhook changes the same rental to `payment_status = paid`.
- [ ] Confirm the admin calendar updates without a manual reload (allow up to 15 seconds).
- [ ] Confirm the audit log records relevant admin changes and payment/hold events.
- [ ] Repeat and let the timer expire; confirm the unpaid rental is cancelled and availability returns.
- [ ] Confirm a second user cannot book overlapping dates for the same test vehicle.
- [ ] Confirm ordinary public Reserve buttons still enter Wheelbase throughout the test.

## Operational and security checks

- [ ] Run RLS tests as anonymous visitor, normal customer, wrong customer, and admin.
- [ ] Confirm customers cannot read another customer's rental, documents, messages, identity status, or pending booking.
- [ ] Confirm only service-role/webhook code can record Stripe payment success.
- [ ] Confirm only admins can refund deposits or change operational rental states.
- [ ] Confirm uploaded documents are private and accessed with short-lived signed URLs.
- [ ] Confirm vehicle-image uploads reject unsupported/oversized files after compression rules.
- [ ] Enable database backups; consider PITR before taking live payments.
- [ ] Configure application/error monitoring and alerts for webhook failures and cron failures.
- [ ] Review Supabase Auth, Postgres, Edge Function, Stripe, Resend, and Twilio logs during launch.
- [ ] Add privacy disclosures for identity verification/document storage and obtain legal review.
- [ ] Define a documented manual/non-biometric verification alternative when required.
- [ ] Confirm Terms, Privacy Policy, cancellation terms, mileage policy, deposit terms, and rental agreement are final.

## Performance status

Latest `npm run perf:check`: passing.

- Built-in vehicle images: each under 200 KB WebP budget.
- Complete built-in fleet: under 3 MB budget.
- Homepage background: under 200 KB WebP budget.
- Client portal JavaScript: under 180 KB gzip budget.
- Admin portal JavaScript: under 180 KB gzip budget.
- Only one public vehicle image is eager-loaded.
- Admin uploads target 1200x900, 300 KB, with a 450 KB hard limit.

Run `npm run perf:check` after any portal, image, or public-fleet change.

## Deferred work: custom vehicle detail pages

No vehicle-detail page was coded during the discussion; it remains a deliberate pre-cutover task.

- [ ] Build one reusable `vehicle.html?id=<supabase-vehicle-id>` page.
- [ ] Build a separate content-only `vehicle-details.js`.
- [ ] Load main photo, gallery, features, pricing, description, and selected dates/times from Supabase.
- [ ] Add private preview access so it can be tested without public links.
- [ ] Keep Wheelbase availability and Reserve buttons unchanged during development.
- [ ] Optimize all additional gallery uploads through the existing admin compression pipeline.
- [ ] Perform accessibility, mobile, structured-data, and SEO review.
- [ ] Upload/publish only when the custom booking cutover is approved.

## Custom-booking cutover checklist (not for the hybrid launch)

Do not remove Wheelbase availability until every item is complete.

- [ ] Replace the internal test vehicle with verified mappings for every real vehicle.
- [ ] Ensure Supabase has the correct rate, deposit, photos, VIN/plate, status, and availability for every car.
- [ ] Import/reconcile all future Wheelbase reservations into the admin calendar.
- [ ] Define the final synchronization or one-time cutover time so double bookings cannot occur.
- [ ] Freeze booking changes briefly during final reconciliation if necessary.
- [ ] Test simultaneous booking attempts and admin calendar blocks.
- [ ] Test turnaround buffers, extensions, vehicle switches, cancellations, and returns.
- [ ] Change public booking buttons only after written approval.
- [ ] Monitor the first live custom bookings in real time.
- [ ] Keep a documented rollback path to Wheelbase during the initial cutover window.

## Tomorrow's recommended order

1. Connect Resend SMTP and successfully receive a numeric email OTP.
2. Verify/recover the two phone OTP Edge Functions and complete one phone verification.
3. Back up/preflight Supabase and apply only missing migrations in dependency order.
4. Deploy the updated non-Wheelbase Edge Functions and configure secrets/webhooks.
5. Deploy the client portal to `login.rentmect.com` and the admin portal to its chosen hostname.
6. Run the complete Booking Preview acceptance test in Stripe test mode.
7. Fix any blockers found in the real browser flow.
8. Run security/RLS checks and `npm run perf:check` again.
9. Deploy the public hybrid site while preserving Wheelbase availability and Reserve actions.
10. Schedule the vehicle-detail/custom-booking cutover as a separate release.

## Release decision

The hybrid website is ready to release only when all critical Auth, phone verification, Supabase migration, Stripe test-mode, admin-calendar, security, and deployment checks above pass. The custom flow must remain a controlled Booking Preview until then. Wheelbase should remain the public availability/checkout fallback until the separate custom-booking cutover checklist is complete.
