# Rent Me CT production status — July 23, 2026

## Safe backend state now deployed

- Supabase CLI is linked and future SQL changes are tracked as migrations.
- `rentals.updated_at` and its update trigger are deployed; database lint has
  zero error-level findings.
- Anonymous access to `rentals` and `pending_bookings` is closed. A complete
  anonymous scan exposes rows only from the intended public `vehicles` table.
- PostgreSQL SSL enforcement is enabled.
- `send-phone-code` and `check-phone-code` authenticate the caller before any
  phone validation or Twilio request.
- The Stripe function restricts Checkout and Identity return URLs to the
  configured client portal.
- Live Stripe payment creation is paused unless the server-only
  `RENTMECT_LIVE_PAYMENTS_ENABLED=true` flag is deliberately configured.
  Webhook processing and authorized refunds remain available.
- The unconfigured email worker and automatic deposit-release cron jobs are
  paused instead of failing silently.
- SendGrid is configured with the verified `rentmectservices@gmail.com`
  sender. A controlled production test was accepted by SendGrid, the email
  queues were confirmed empty, and `rentmect-email-worker-every-minute` is
  enabled. Automatic deposit release remains paused.
- The deployed non-Wheelbase Edge Functions match the reviewed local source.

## Portal artifacts ready for deployment

- Client and admin production builds pass.
- Booking contract audit passes.
- Performance budgets pass.
- Root, client, and admin dependency audits report zero vulnerabilities.
- Both portal builds include a browser CSP/referrer policy and fail fast on
  missing or insecure Supabase configuration.
- The hardened client and admin sources are merged into their GitHub `main`
  branches. Both GitHub Pages workflows completed successfully, and the live
  `login.rentmect.com` and `admin.rentmect.com` HTML contains the hardened
  browser policies.

## Remaining external launch gates

1. Configure matching Edge Function/Vault deposit-release secrets, run a
   controlled Stripe test refund, and only then re-enable
   `rentmect-security-deposit-release`.
2. Replace the test client Stripe configuration with a matching environment,
   complete the full test-mode acceptance flow, then explicitly enable live
   payments only when approved.
3. Connect the in-app browser and complete mobile/desktop visual smoke tests.
4. Confirm a restorable database backup. PITR is currently disabled; enabling
   it may add Supabase cost and requires an owner decision.

## Explicit exclusion

No Wheelbase source, function, secret, deployment, API, or public booking flow
was modified.
