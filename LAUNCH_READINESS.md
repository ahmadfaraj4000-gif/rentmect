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

## Must complete before taking live payments

1. In Supabase SQL Editor, run `supabase/admin_audit_and_deposit_controls.sql`.
2. Run `supabase/stripe_identity_verification.sql` after the audit/deposit migration.
3. Deploy the updated `supabase/functions/stripe-web-hook/index.ts`. The live
   endpoint currently responds like the previous function, so the local refund
   and scheduler changes are not live yet.
4. Set Edge Function secrets: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
   `SUPABASE_SERVICE_ROLE_KEY`, and a new high-entropy
   `RENTMECT_DEPOSIT_RELEASE_SECRET`.
5. Enable Stripe Identity in the Stripe Dashboard and complete any required business verification.
6. In Stripe, point the webhook to
   `https://<project-ref>.supabase.co/functions/v1/stripe-web-hook/webhook` and
   subscribe to `checkout.session.completed`, `refund.created`,
   `refund.updated`, `refund.failed`, `identity.verification_session.verified`,
   `identity.verification_session.requires_input`, `identity.verification_session.processing`,
   and `identity.verification_session.canceled`.
7. Add Supabase Vault secrets `project_url`, `project_anon_key`, and
   `rentmect_deposit_release_secret`. The last value must exactly match the Edge
   Function secret. Then run `supabase/security_deposit_release_schedule.sql`.
8. Replace the client portal's local/placeholder `VITE_CLIENT_PORTAL_URL` with
   its public HTTPS URL before building the deployment. This controls password
   reset redirects.
9. Set `RENTMECT_CLIENT_PORTAL_URL` on the Stripe Edge Function to the public HTTPS
   client-portal URL so Identity return redirects cannot fall back to localhost.
10. Confirm the deployed Edge Function uses Stripe live keys when ready for real
   charges. The repository cannot inspect hosted Supabase secrets, so live mode
   is not currently confirmed.
11. Run two Stripe test-mode bookings: one renter age 24 ($500 deposit) and one
   age 25 ($300 deposit). Complete a clean return, test the admin refund button,
   and verify the Stripe refund plus audit record.
12. Run a Stripe Identity test session with a matching test document/selfie and a
   failed/retry session. Confirm pickup stays blocked until status is `verified`.
13. Have counsel review the July 19 Stripe Identity privacy disclosure and define
   an operational non-biometric/manual alternative for customers who cannot or do
   not consent to selfie verification where applicable law requires one.

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
