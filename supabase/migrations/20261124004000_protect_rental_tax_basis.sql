begin;
-- Only contract creation and reviewed schedule changes calculate these fields.
create function public.protect_rental_tax_basis() returns trigger language plpgsql set search_path=public as $$
begin
  if new.contract_sales_tax_rate is distinct from old.contract_sales_tax_rate or new.tourism_surcharge is distinct from old.tourism_surcharge then
    raise exception 'Rental tax terms are calculated from the agreement.' using errcode='42501';
  end if;
  return new;
end $$;
create trigger aaaa_protect_rental_tax_basis before update of contract_sales_tax_rate,tourism_surcharge on public.rentals
for each row execute function public.protect_rental_tax_basis();
commit;
