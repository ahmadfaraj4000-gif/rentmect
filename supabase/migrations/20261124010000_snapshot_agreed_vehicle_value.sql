begin;
alter table public.rentals add column contract_agreed_vehicle_value numeric(12,2) check(contract_agreed_vehicle_value>0);
create function public.capture_agreed_vehicle_value() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    new.contract_agreed_vehicle_value:=null;
    if new.contract_sales_tax_rate in (0.0635,0.0775) then
      select agreed_vehicle_value into strict new.contract_agreed_vehicle_value from vehicles where id=new.vehicle_id;
    end if;
  elsif new.contract_agreed_vehicle_value is distinct from old.contract_agreed_vehicle_value then
    raise exception 'The agreed vehicle value is recorded at contract inception.' using errcode='42501';
  end if;
  return new;
end $$;
create trigger aaab_capture_contract_vehicle_value before insert or update of contract_agreed_vehicle_value on public.rentals
for each row execute function public.capture_agreed_vehicle_value();
commit;
