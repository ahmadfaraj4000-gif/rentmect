# TollSpot Customer API integration plan

Status: base production integration deployed July 25, 2026 and Customer API
connectivity confirmed July 27, 2026. The July 27 automated-billing upgrade is
implemented and build/audit verified locally; its database migration, Edge
Functions, schedule, and portal builds still require coordinated deployment.

Source contract: TollSpot Customer API OpenAPI 3.1.0, version 1.0.0,
provided July 25, 2026.

## Current deployment

- The Supabase project is named `Rent Me CT`.
- Migration `20260725193000_tollspot_customer_api.sql` is applied remotely.
- The `tollspot-sync` Edge Function is active and rejects unauthorized calls.
- `TOLLSPOT_API_KEY`, `TOLLSPOT_API_BASE_URL`, `TOLLSPOT_API_VERSION`, and a
  dedicated scheduler secret are present in Supabase Secrets.
- The currently deployed scheduler remains off until the July 27 upgrade is
  deployed with `supabase/tollspot_automatic_schedule.sql`.
- The admin portal Tolls UI builds successfully but has not been published
  because its repository already contains unrelated uncommitted work.
- TollSpot's July 24 onboarding email identifies the production base URL as
  `https://selfserve.tollspot.app/api`.
- The deployed read-only `health` action connected successfully on July 27,
  2026 using API version `1.0.0` and returned 29 visible vehicles.
- The vendor's example response uses `transaction_type: "TOLL"` even though
  the OpenAPI schema declares `TOLLS`. The adapter normalizes `TOLL` to the
  database's canonical `TOLLS` value.
- The upgrade makes scheduled reads controllable in Admin > Settings > Billing
  Automation and uses a 30-minute overlapping poll.

## Outcome

Rent Me CT synchronizes every real fleet vehicle and its plate assignment,
polls TollSpot for new transactions, and safely matches each toll to the exact
vehicle and rental. A deterministic toll automatically becomes an idempotent
pending rental charge. Ambiguous matches, parking, and violations remain in the
admin exception queue.

Automatic charge creation adds the amount due to the rental; it does not debit
the customer's card. The customer can pay through the existing Stripe
rental-charge flow, or an authorized admin can use the saved-card action.

The intended production flow is:

```text
Rent Me CT fleet
  -> server-only TollSpot sync
  -> TollSpot vehicles, plates, and assignments

TollSpot toll-charge API
  -> scheduled server-only polling
  -> idempotent transaction storage
  -> deterministic vehicle + rental matching
  -> automatic pending rental_charge_item
  -> exception queue only when deterministic matching is unsafe
  -> existing Stripe/customer-portal payment flow
```

## Credential handling

- The API credential was removed from `LAUNCH_READINESS.md`.
- A local copy is stored only as `TOLLSPOT_API_KEY` in
  `supabase/.env.local`, which is covered by the project's `.env.*` ignore
  rule and has owner-only file permissions.
- The credential must never use the existing generic `API_KEY`; that name is
  already consumed by the Wheelbase integration.
- The credential must never be placed in either Vite application, a `VITE_*`
  variable, SQL, Markdown, logs, browser storage, or a database table.
- `TOLLSPOT_API_KEY` was deployed to the verified linked Supabase project's
  Edge Function secret store on July 25, 2026.
- Rotate the TollSpot key before production. It appeared in plaintext in the
  vendor onboarding email and in a July 27 troubleshooting screenshot.

The server will also require:

- `TOLLSPOT_API_BASE_URL=https://selfserve.tollspot.app/api`
- `TOLLSPOT_API_VERSION=1.0.0`
- `TOLLSPOT_SYNC_SECRET`: only if a scheduled invocation cannot use a native
  authenticated Supabase mechanism

## What the supplied contract establishes

Authentication and transport:

- HTTPS is mandatory.
- Every request sends the API key in `X-API-KEY`.
- Every request explicitly sends `X-API-VERSION: 1.0.0`, even though TollSpot
  currently defaults an omitted version to its latest stable version.
- List endpoints use zero-based `page` and `limit`; `limit` has a maximum of
  100.
- Structured errors include authentication, validation, missing-resource, and
  rate-limit failures.

Available operations:

| Area | Operations |
| --- | --- |
| Vehicles | Add a vehicle; list vehicles |
| Plates | Add a license plate; list license plates |
| Assignments | Assign a plate; list assignments; end an assignment |
| Charges | List toll charges with date, plate, vehicle, or transponder filters |

The contract does not describe webhooks. The existing
`supabase/functions/tollspot-webhook` is therefore not the primary integration
path for this API version and must remain undeployed or disabled unless TollSpot
supplies a separate webhook contract.

## Remaining confirmations from TollSpot

The production base URL is confirmed and the read-only health check succeeds.
The remaining vendor details should still be confirmed and monitored during
the controlled launch:

1. Whether a separate sandbox exists and whether separate sandbox credentials
   are available. The supplied key is production-prefixed and successfully
   accesses the production Customer API.
2. Whether API access requires any source-IP allowlisting. The current
   Supabase-hosted health request succeeds without additional allowlisting.
3. Rate limits, `Retry-After` behavior, request timeouts, and any daily usage
   quota.
4. Whether `from_date` and `to_date` filter `posted_time`, `exit_time`, or
   another date.
5. Maximum supported backfill range and the normal maximum delay between
   `exit_time` and `posted_time`.
6. Whether POST operations support idempotency keys, and what uniqueness rules
   TollSpot applies to `local_id`, VIN, and plate.
7. How a vehicle's status, make, model, or VIN should be corrected after it is
   added. The contract has no vehicle update operation.
8. How an incorrectly entered plate should be corrected. The contract has no
   plate update or delete operation.
9. Whether `assigned_at` can be historical and what timestamp should be used
   when onboarding an existing fleet.
10. Whether ending a plate assignment changes TollSpot's ability to return
    later-posted charges for the prior assignment.
11. The apparent plate-length inconsistency: plate creation allows 12
    characters, while toll filtering allows 8.
12. Whether `amount` already includes every TollSpot/provider fee. Rent Me CT
    must not add the same fee twice.

Answers and pilot findings will be recorded in this document before enabling
scheduled production sync.

## Current repository assets to reuse

The existing framework already provides useful safety boundaries:

- `tollspot_vehicle_mappings`
- `tollspot_transactions`
- admin-only row-level security
- an admin RPC for matching a transaction to a rental
- an admin RPC for creating a pending rental charge
- provider-ID deduplication concepts
- an existing customer-visible `rental_charge_items` and Stripe payment flow

The implementation will evolve those assets rather than create a second,
competing set of toll tables. The webhook-specific raw-event table can remain
for a future webhook contract, but polled API records will not be disguised as
webhook deliveries.

## Phase 1: production-ready database model

Create one timestamped migration under `supabase/migrations/` that safely
supersedes `supabase/tollspot_integration_framework.sql`.

### Fleet mapping

Extend `tollspot_vehicle_mappings` with:

- local `vehicle_id`
- TollSpot vehicle ID
- TollSpot license-plate ID
- active TollSpot assignment ID
- normalized TollSpot vehicle type
- plate, state, and country snapshots
- assignment effective time
- desired provider status
- last successful sync time
- last attempted sync time
- sync state: `pending`, `synced`, `drifted`, `error`, or `disabled`
- sanitized last error code/message

Keep provider identifiers as text in the database even though version 1.0.0
currently returns integers. This avoids unnecessary schema changes if the
provider changes identifier representation.

Add a separate plate-assignment history table. A single mutable mapping row is
not enough to prove which plate was assigned to a vehicle when a historical
toll occurred.

### Vehicle prerequisites

The current fleet editor does not collect every TollSpot field. Add server-side
or admin-only fields for:

- TollSpot eligibility/enabled flag
- normalized TollSpot type:
  `SEDAN`, `SUV`, `TRUCK`, `MOTORCYCLE`, `RV`, or `TRAILER`
- plate state
- plate country, defaulting to `US` only after staff confirmation
- plate effective timestamp
- model year when it cannot be reliably obtained from the VIN

Do not replace the existing customer-facing `vehicle_type`. Values such as
“Compact SUV” are useful to customers but are not valid TollSpot enum values.

Exclude the fixed Booking Flow Test Vehicle and any unpublished test inventory
from TollSpot by default.

### Toll transactions

Extend the existing `tollspot_transactions` table to preserve every relevant
field in the supplied `TollCharge` schema:

- TollSpot charge ID
- TollSpot vehicle ID and partner vehicle ID
- posted time
- entry time and location
- exit/occurrence time and location
- amount and currency
- transaction type: canonical `TOLLS`, `PARKING`, or `VIOLATION`; normalize
  TollSpot's observed `TOLL` value to `TOLLS`
- plate, state, and country
- transponder number
- agency
- host ID
- VIN snapshot
- complete raw provider record
- ingestion and update timestamps
- match method and confidence
- review status and review reason
- linked vehicle, rental, and rental charge item

Use the TollSpot charge ID as the provider idempotency key. A repeated poll must
update the same row and must never create a second rental charge.

`exit_time` is the canonical occurrence time because the contract defines it as
the exit or transaction timestamp. `posted_time` remains separate because it
may be much later.

### Sync runs and operations

Add:

- `tollspot_sync_runs` for start/end time, mode, date window, pages, counts,
  result, and sanitized failure details
- `tollspot_sync_operations` for retryable vehicle/plate/assignment work
- unique constraints that prevent duplicate active mappings and duplicate
  provider operations
- indexes for unmatched transactions, rental history, provider IDs, plate
  history, and recent failed runs

Only `service_role` may write provider-ingestion and sync tables. Authenticated
admins receive the minimum read/execute permissions needed for the admin UI.
Customers and anonymous users receive no access to raw TollSpot data.

### Database functions

Replace or harden the current RPCs with:

- a service-role upsert function for normalized TollSpot charges
- a deterministic match function
- an admin-only manual-match function
- an admin-only ignore/reopen function with a required reason
- an admin-only, concurrency-safe charge-creation function
- an admin view/RPC that returns only the TollSpot fields needed by the portal

Every admin action will write to the existing admin/rental audit trail.

## Phase 2: server-only TollSpot client

Create:

- `supabase/functions/_shared/tollspot-client.ts`
- `supabase/functions/tollspot-sync/index.ts`
- an explicit `[functions.tollspot-sync]` entry in `supabase/config.toml`

The shared client will:

1. Read the key and base URL only from Edge Function secrets.
2. reject a missing key, a non-HTTPS base URL, or a host outside the configured
   TollSpot origin;
3. send `X-API-KEY` and `X-API-VERSION: 1.0.0`;
4. apply request timeouts;
5. parse and validate success and error bodies;
6. paginate from page 0 with a limit of 100;
7. stop when accumulated rows reach `total`, with a defensive page ceiling;
8. honor `Retry-After` and retry network errors, 429s, and bounded 5xx failures
   with jittered backoff;
9. not retry authentication or validation failures blindly; and
10. never log secrets, authorization headers, full VINs, transponders, or raw
    customer-related payloads.

The Edge Function will support separately authorized actions:

- `health`: configuration and API-authentication check without exposing secrets
- `sync_fleet`: reconcile eligible vehicles, plates, and assignments
- `sync_tolls`: poll and ingest toll charges
- `backfill_tolls`: bounded, admin-triggered historical import
- `run_all`: scheduled fleet reconciliation followed by toll ingestion

Admin calls require a valid Supabase user JWT plus a server-side
`public.is_admin()` check. Scheduled calls use a server-controlled identity or
dedicated secret and cannot accept arbitrary URLs or date ranges.

## Phase 3: fleet reconciliation

For each explicitly enabled local vehicle:

1. Validate VIN, make, model, normalized type, plate, state, country, and
   effective timestamp before contacting TollSpot.
2. List provider vehicles and match first by `local_id = vehicles.id`.
3. If no match exists, cautiously check the stored provider mapping and VIN.
4. POST a new vehicle only when no unique match exists.
5. Use:
   - `local_id`: local vehicle UUID
   - `easy_name`: local fleet name
   - `vin`: first 12 VIN characters by default, as permitted by the contract
   - `vehicle_make`: local brand
   - `vehicle_model`: local model
   - `vehicle_type`: explicit normalized enum
   - `status`: mapped provider status at creation time
6. List plates and reuse an exact normalized plate/state/country match.
7. Add the plate only if no exact match exists.
8. List assignments before adding one.
9. End the previous assignment at the staff-confirmed effective time when a
   plate changes.
10. Create the new assignment and store every returned provider ID.

Local status mapping:

| Rent Me CT status | TollSpot desired status |
| --- | --- |
| available | `AVAILABLE` |
| reserved, rented | `IN_USE` |
| maintenance, unavailable | `OUT_OF_SERVICE` |
| inactive | `RETIRED` |

Because the contract cannot update an existing vehicle, the first
implementation will record status drift rather than invent an unsupported
request. Production status synchronization remains disabled until TollSpot
documents the correct operation.

POST calls will use a read-before-create strategy because the contract does not
advertise idempotency keys. Ambiguous matches stop reconciliation and enter the
admin review queue.

## Phase 4: toll polling and ingestion

### Initial import

- Run a small sandbox query first and verify pagination and timestamps.
- Backfill one pilot vehicle over a short, known interval.
- Reconcile counts and amounts against the TollSpot dashboard.
- Expand the backfill only after the pilot matches exactly.

### Incremental schedule

- Start with manual sync.
- Move to a disabled-by-default scheduled run after shadow-mode approval.
- Poll with an overlapping lookback window so late-posted charges are found.
- Make the lookback configurable; use 30 days as an initial conservative value
  only after TollSpot confirms date-filter semantics and posting delays.
- Upsert every result by TollSpot charge ID, making overlap safe.
- Record the last fully successful window but never rely on a cursor alone.
- Keep failed runs retryable without advancing the successful checkpoint.

All pages are processed before a run is marked successful. A partial run
remains visible and is safe to retry.

## Phase 5: deterministic rental matching

Matching occurs after ingestion and never trusts a customer-supplied ID.

1. Resolve the local vehicle through the TollSpot vehicle mapping.
2. If needed, use exact normalized plate/state/country plus the historical
   assignment interval.
3. Use VIN only as a guarded fallback.
4. Convert TollSpot UTC timestamps and the local rental schedule consistently
   with the repository's `America/New_York` business timezone.
5. Compare the occurrence time to the canonical rental pickup/return interval,
   including approved extensions.
6. Match automatically only when exactly one rental is valid.
7. Route zero matches or multiple matches to `needs_review`.
8. Store the match method, candidate count, and non-sensitive reason.

The existing date-only match RPC will be upgraded to exact timestamps. It must
continue to reject a rental for a different vehicle or a toll outside the
allowed rental interval.

Parking and violation transactions are ingested but always require explicit
review. The system will not assume they are ordinary pass-through tolls.

## Phase 6: admin operations UI

Add a dedicated `Tolls` section to the admin portal. It will use the
admin-safe views/RPCs and Edge Function actions, never the TollSpot API
directly.

The section will show:

- connection/configuration health without revealing the key
- last successful and failed sync
- fleet mapping status and validation errors
- open provider drift
- unmatched and ambiguous transactions
- matched transactions awaiting review
- charge-created, paid, ignored, and disputed history
- filters for date, vehicle, plate, agency, type, and status

Admin actions:

- test connection
- synchronize one vehicle or the eligible fleet
- fetch current charges
- run a bounded backfill
- inspect normalized and raw provider details with sensitive fields masked
- accept the proposed rental match
- choose a different valid rental
- ignore/reopen with an audited reason
- create one pending customer charge

The charge confirmation will display toll amount, any separately configured
admin fee, tax treatment, customer, rental, vehicle, and TollSpot charge ID.
Taxability and any Rent Me CT administrative fee remain explicit business-rule
settings; they will not be inferred from the API contract.

The existing client portal already lists unpaid `rental_charge_items` and opens
Stripe Checkout. TollSpot does not need to be exposed directly to the customer
portal in the first release.

## Phase 7: security, privacy, and operational controls

- Keep all TollSpot traffic server-to-server.
- Use least-privilege RLS and RPC grants.
- Mask VINs and transponders in normal admin list views.
- Retain raw provider data only for the approved reconciliation/audit period.
- Redact request headers and raw payloads from logs and error notifications.
- Validate all provider responses at the trust boundary.
- Constrain manual backfill dates and page counts.
- Prevent concurrent scheduled runs with a database advisory lock or active-run
  lease.
- Use unique constraints and row locks for charge idempotency.
- Alert admins on repeated 401, 429, schema-validation, or stalled-sync errors.
- Add the new alert types to the existing admin notification framework without
  including credentials or full provider records.
- Store scheduled-call secrets through Supabase Secrets/Vault references, never
  as literals in cron SQL.

## Phase 8: verification

### Contract and client tests

- required headers and API version
- timeout and HTTPS/origin enforcement
- page 0 and multi-page traversal
- maximum page-size behavior
- 400, 401, 404, 422, 429, and 5xx handling
- malformed or schema-drifted provider responses
- redacted logs

### Fleet tests

- valid vehicle creation
- free-form local type to TollSpot enum mapping
- VIN privacy truncation
- existing remote vehicle/plate reuse
- duplicate POST prevention after a timeout
- plate replacement with assignment history
- missing state/country/effective time
- ambiguous remote records
- exclusion of test and disabled vehicles

### Toll-ingestion tests

- repeated polling creates one transaction
- an updated provider record updates but does not duplicate the row
- late posting is captured by the overlap window
- partial pagination failure resumes safely
- all `TollCharge` fields normalize correctly
- `TOLLS`, `PARKING`, and `VIOLATION` retain their types

### Matching and billing tests

- exact vehicle and rental match
- plate reassignment boundary
- UTC/New York date boundary and daylight-saving transitions
- approved rental extension
- no rental and overlapping-rental ambiguity
- different-vehicle rejection
- concurrent charge-creation requests produce one charge
- no customer billing on ingestion or matching
- ignored/disputed transactions cannot create a charge without reopening
- created charges appear in the existing customer portal

### Authorization tests

- anonymous and customer users cannot read TollSpot tables
- non-admin users cannot invoke sync or review RPCs
- admins cannot retrieve the API key
- only service-role code can ingest provider data

Add a rollback-only SQL audit for database invariants and a mock-TollSpot test
runner that uses fixtures derived from the OpenAPI examples, never the live
credential.

## Rollout sequence

1. Obtain the blocking TollSpot answers and sandbox base URL.
2. Rotate the credential if its prior plaintext location may have been exposed.
3. Place the approved key and base URL in Supabase Secrets.
4. Deploy the database migration with sync disabled.
5. Deploy the shared client and `tollspot-sync` Edge Function.
6. Run contract tests against a mock and then the sandbox.
7. Enable and reconcile one non-test pilot vehicle.
8. Import a small known date window and compare every result with TollSpot.
9. Release the admin `Tolls` review UI.
10. Run shadow mode with no customer-charge creation for an agreed observation
    period.
11. Enable manual creation of pending rental charges.
12. Reconcile charges and payments daily during the pilot.
13. Enable scheduled polling only after duplicate, matching, alerting, and
    rollback tests pass.
14. Expand fleet coverage gradually.

## Rollback

Rollback is non-destructive:

- set `TOLLSPOT_SYNC_ENABLED=false`;
- disable the schedule;
- leave historical mappings, transactions, and audit records intact;
- hide admin actions behind the feature flag;
- rotate/revoke the API key if credential behavior is suspect; and
- continue handling already-created rental charges through the existing billing
  workflow.

No rollback step drops toll records or customer payment history.

## Definition of done

The integration is production-ready only when:

- no TollSpot secret exists in tracked or frontend files;
- the production key is stored only in Supabase Secrets and has been rotated if
  necessary;
- all blocking contract questions are answered;
- every eligible fleet vehicle has an unambiguous provider mapping;
- repeated and overlapping polls produce no duplicate transactions;
- exact-time rental matching passes timezone, extension, and plate-history
  tests;
- deterministic ingestion automatically creates an audited, idempotent pending
  rental charge but never directly debits the customer's card;
- ambiguous matches require admin review;
- customer and anonymous RLS tests pass;
- a failed sync alerts staff without exposing sensitive data;
- pilot counts and dollar totals reconcile with TollSpot; and
- the disable-and-rollback procedure has been tested.
