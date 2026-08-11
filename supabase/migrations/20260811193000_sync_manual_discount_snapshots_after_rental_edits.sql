-- A rental amendment must refresh the display snapshots used to explain a
-- reservation-only manual discount. The payable total was already canonical,
-- but stale pre-discount values could still show the prior rental duration.

create or replace function public.sync_manual_discount_snapshots_on_rental()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_pre_discount_rental numeric;
  v_pre_discount_tax numeric;
begin
  if coalesce(new.manual_discount_amount, 0) > 0 then
    v_pre_discount_rental := round(
      coalesce(new.rental_total, 0) + coalesce(new.manual_discount_amount, 0), 2
    );
    v_pre_discount_tax := round(
      (v_pre_discount_rental + coalesce(new.taxable_service_fee_total, 0)) * 0.0635, 2
    );
    new.pre_manual_discount_rental_total := v_pre_discount_rental;
    new.pre_manual_discount_tax_amount := v_pre_discount_tax;
    new.manual_discount_tax_savings := greatest(
      0, round(v_pre_discount_tax - coalesce(new.tax_amount, 0), 2)
    );
  end if;
  return new;
end;
$$;

drop trigger if exists rentals_sync_manual_discount_snapshots on public.rentals;
create trigger rentals_sync_manual_discount_snapshots
before update of rental_total, tax_amount, manual_discount_amount,
  taxable_service_fee_total
on public.rentals
for each row execute function public.sync_manual_discount_snapshots_on_rental();

update public.rentals
set pre_manual_discount_rental_total = round(
      coalesce(rental_total, 0) + coalesce(manual_discount_amount, 0), 2
    ),
    pre_manual_discount_tax_amount = round(
      (
        coalesce(rental_total, 0) + coalesce(manual_discount_amount, 0)
          + coalesce(taxable_service_fee_total, 0)
      ) * 0.0635, 2
    ),
    manual_discount_tax_savings = greatest(
      0,
      round(
        (
          coalesce(rental_total, 0) + coalesce(manual_discount_amount, 0)
            + coalesce(taxable_service_fee_total, 0)
        ) * 0.0635,
        2
      ) - coalesce(tax_amount, 0)
    )
where coalesce(manual_discount_amount, 0) > 0;

notify pgrst, 'reload schema';
