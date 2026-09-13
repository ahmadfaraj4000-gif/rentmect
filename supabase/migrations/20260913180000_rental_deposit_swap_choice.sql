-- Allow audited amendments to change the deposit requirement. Captured money and
-- deposit allocations remain separate; no refund is implied by a lower price.

do $migration$
declare
  definition text;
  obsolete_guard text := $guard$  if lower(coalesce(v_rental.payment_status, 'pending')) = 'paid'
     and abs(v_security_deposit - coalesce(v_rental.security_deposit, 0)) > 0.005 then
    raise exception 'A paid rental deposit cannot be rewritten. Keep the held deposit unchanged and use the protected deposit adjustment workflow.';
  end if;$guard$;
begin
  select pg_get_functiondef('public.admin_preview_rental_amendment_without_manual_discount(uuid,uuid,date,text,date,text,numeric,numeric)'::regprocedure) into definition;
  if position(obsolete_guard in definition) = 0 then
    raise exception 'Deposit preview definition changed; review before migrating.';
  end if;
  execute replace(definition, obsolete_guard, '-- Deposit requirement changes are reconciled against captured payments.');
end;
$migration$;

do $migration$
declare
  definition text;
  obsolete_guard text := $guard$  if (
    v_rental.paid_at is not null
    or lower(coalesce(v_rental.payment_status, '')) in ('paid', 'partially_paid', 'partial')
  ) and abs(
    coalesce((v_preview #>> '{new,security_deposit}')::numeric, 0)
      - coalesce(v_rental.security_deposit, 0)
  ) > 0.005 then
    raise exception 'The captured deposit must stay at %. Vehicle and schedule changes only reprice the rental portion.',
      to_char(coalesce(v_rental.security_deposit, 0), 'FM$999,999,990.00');
  end if;$guard$;
begin
  select pg_get_functiondef('public.admin_preview_rental_amendment(uuid,uuid,date,text,date,text,numeric,numeric)'::regprocedure) into definition;
  if position(obsolete_guard in definition) = 0 then
    raise exception 'Deposit preview definition changed; review before migrating.';
  end if;
  execute replace(definition, obsolete_guard, '-- Deposit requirement changes are reconciled against captured payments.');
end;
$migration$;
