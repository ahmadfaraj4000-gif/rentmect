begin;
set local lock_timeout='150ms';
set local statement_timeout='15s';
-- Modify only audited reason/note minimums in current definitions, preserving
-- unrelated deployed fixes, permissions, inspection and financial guards.
do $migration$
declare f record; original text; changed text; line text; revised text; c record;
begin
 for f in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname=any(array[
  'admin_activate_rental_with_emergency_exception',
  'admin_add_rental_emergency_exception_scope',
  'admin_adjust_external_rental_payment',
  'admin_agree_extension_rate',
  'admin_apply_manual_rental_discount',
  'admin_apply_rental_amendment',
  'admin_assign_tollspot_transaction_to_rental',
  'admin_cancel_rental',
  'admin_complete_rental_step',
  'admin_correct_external_payment',
  'admin_correct_flexible_payment',
  'admin_correct_legacy_external_payment',
  'admin_correct_payment_amount',
  'admin_hold_deposit_review',
  'admin_ignore_tollspot_transaction',
  'admin_inspect_and_complete_rental_return',
  'admin_inspect_and_complete_rental_return_core',
  'admin_merchant_workspace',
  'admin_override_vehicle_maintenance',
  'admin_preview_rental_extension',
  'admin_preview_rental_extension_revision',
  'admin_preview_rental_rate_change',
  'admin_preview_vehicle_swap',
  'admin_refund_external_payment',
  'admin_refund_external_payment_v1',
  'admin_correct_external_payment_v1',
  'admin_restore_cancelled_unpaid_rental',
  'admin_set_rental_payment_deadline',
  'admin_sign_rental_agreement_in_office',
  'admin_ticket_action',
  'admin_ticket_customer_flag',
  'enforce_rental_odometer_gate',
  'prepare_before_pickup_deposit_refund',
  'reserve_rental_payment_refund',
  'service_apply_deposit_review',
  'service_apply_deposit_to_charges',
  'service_deduct_deposit_charges',
  'service_reclassify_legacy_deposit']) loop
  original:=pg_get_functiondef(f.oid); changed:='';
  foreach line in array string_to_array(original,E'\n') loop
   revised:=line;
   if line ~* '(reason|note)' and line ~* 'length[[:space:]]*\(' then
    revised:=regexp_replace(revised,'(<[[:space:]]*)(3|5|8|10|20)\M','\11','g');
    revised:=regexp_replace(revised,'(>=[[:space:]]*)(3|5|8|10|20)\M','\11','g');
   end if;
   revised:=regexp_replace(revised,' of at least (3|5|8|10|20|five) characters','','g');
   revised:=regexp_replace(revised,' in at least (3|5|8|10|20) characters','','g');
   revised:=regexp_replace(revised,' \(at least (3|5|8|10|20) characters\)','','g');
   revised:=replace(revised,' (10–1000 characters)',' (required; up to 1000 characters)');
   changed:=changed||revised||E'\n';
  end loop;
  if changed<>original||E'\n' then execute changed; end if;
 end loop;
 -- Table checks enforce the same nonblank rule as the API. Do not drop audit
 -- records or remove other checks. Existing rows satisfy the relaxed checks.
 for c in select con.oid,con.conname,con.conrelid,pg_get_constraintdef(con.oid) definition
 from pg_constraint con join pg_class t on t.oid=con.conrelid join pg_namespace n on n.oid=t.relnamespace
 where n.nspname='public' and con.contype='c'
 and pg_get_constraintdef(con.oid) ~* '(reason|note)'
 and pg_get_constraintdef(con.oid) ~* 'length\(' loop
  changed:=regexp_replace(c.definition,'(>=[[:space:]]*)(3|5|8|10|20)\M','\11','g');
  if changed<>c.definition then
   execute format('alter table %s drop constraint %I, add constraint %I %s',c.conrelid::regclass,c.conname,c.conname,changed);
  end if;
 end loop;
end $migration$;
notify pgrst,'reload schema';
commit;
