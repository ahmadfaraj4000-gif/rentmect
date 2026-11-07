# Complete discount regression schema

`discount_full_schema.sql.gz` is a schema-only capture of the isolated PostgreSQL
17 rehearsal database from the November 6 unified-payment release. It contains
the production application functions, tables, triggers, constraints, policies,
and grants, including the aggregate discount snapshot trigger omitted from the
older discount fixture. It contains no table data or customer records.

Hosted extension integrations are represented by the existing local rehearsal
schema; outbound provider services do not run. Realtime broadcasts may produce
expected warnings. This fixture tests database behavior, not hosted transport.

Inspect with `gzip -dc supabase/tests/fixtures/discount_full_schema.sql.gz`.
Run `python3 tools/test-discount-full-schema.py` with PostgreSQL 17 installed.
The runner starts a temporary local server or accepts an explicitly configured
disposable localhost CI database. It applies the November 7 repair and exercises
the actual discount, extension, payment, deposit, and permission logic.

Update this schema deliberately alongside later database releases; do not replace
it with a reduced stub that drops trigger interactions or security grants.
