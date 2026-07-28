-- Read-only preflight checks for rentmect_hardening.sql.
-- Run this first in Supabase SQL editor. It changes nothing.

select
  table_schema,
  table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'profiles',
    'vehicles',
    'rentals',
    'rental_documents',
    'rental_messages',
    'vehicle_reports',
    'rental_signatures',
    'rental_audit_events'
  )
order by table_name;

select
  table_name,
  column_name,
  data_type,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('rentals', 'profiles', 'rental_signatures')
  and column_name in (
    'payment_status',
    'deposit_status',
    'paid_at',
    'agreement_version',
    'agreement_snapshot',
    'agreement_hash',
    'agreement_signed_at',
    'agreement_signature_name',
    'agreement_ip',
    'agreement_user_agent',
    'mileage_policy',
    'cancellation_terms',
    'admin_notes',
    'blocked_customer',
    'chargeback_count',
    'late_return_count',
    'deposit_held_amount',
    'deposit_released_amount',
    'ip_address',
    'user_agent',
    'vehicle_id',
    'rental_total',
    'tax_amount',
    'security_deposit',
    'signed_at'
  )
order by table_name, column_name;

select
  routine_name,
  routine_type,
  security_type,
  data_type
from information_schema.routines
where specific_schema = 'public'
  and routine_name in (
    'rental_dates_overlap',
    'create_rental_with_lock',
    'sign_rental_agreement'
  )
order by routine_name;

select
  schemaname,
  tablename,
  rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in (
    'profiles',
    'vehicles',
    'rentals',
    'rental_documents',
    'rental_messages',
    'vehicle_reports',
    'rental_signatures',
    'rental_audit_events'
  )
order by tablename;
