-- Require the current agreement for new signatures from both customer and admin RPCs.
-- Existing signed records remain historical evidence and are not rewritten.
begin;

create or replace function public.require_current_rental_agreement()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.agreement_version is distinct from 'rentmect-master-v2026-10-23-unreturned-keys-r1'
     or position($clause$UNRETURNED KEYS AND KEY FOBS
Renter must return all keys and key fobs provided with the Vehicle at the end of the rental. If any key or key fob is not returned, Renter shall be responsible for the actual, reasonable cost of replacement, including necessary cutting, programming, and deactivation of missing keys or key fobs, plus a service fee of two hundred dollars ($200), to the extent permitted by law.
Renter shall also be responsible for documented rental income lost directly because the missing key or key fob makes the Vehicle unavailable for rental, limited to the reasonable time necessary to restore the Vehicle to rental service and any limits imposed by applicable law. Company shall take reasonable steps to minimize this loss and shall not collect duplicate compensation for the same period or expense. Company may deduct authorized amounts from the security deposit or charge the payment method on file, with an itemized statement provided to Renter.$clause$ in coalesce(new.agreement_snapshot, '')) = 0 then
    raise exception 'The rental agreement has been updated. Refresh this page, review the current agreement, and sign again.'
      using errcode = '22023';
  end if;
  return new;
end;
$function$;

revoke all on function public.require_current_rental_agreement() from public;
drop trigger if exists rental_signatures_require_current_agreement on public.rental_signatures;
create trigger rental_signatures_require_current_agreement
before insert on public.rental_signatures
for each row execute function public.require_current_rental_agreement();

commit;
