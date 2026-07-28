-- Avoid treating words such as "audit" as the Audi vehicle brand.

create or replace function public.rentmect_oem_mileage_interval(
  p_vehicle text,
  p_service_type text
) returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := lower(coalesce(p_vehicle, ''));
begin
  if p_service_type = 'brake_fluid' then return null; end if;

  if v like '%ford%escape%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 150000 when 'spark_plugs' then 100000 when 'coolant' then 200000 end;
  elsif v like '%kia%soul%' then
    return case p_service_type when 'oil_change' then 6000 when 'tire_service' then 6000
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  elsif v like '%buick%encore%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 45000 when 'spark_plugs' then 97000 when 'coolant' then 150000 end;
  elsif v ~ '(^|[^a-z])audi([^a-z]|$)' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 40000 when 'spark_plugs' then 55000 when 'coolant' then 100000 end;
  elsif v like '%bmw%' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 60000 when 'spark_plugs' then 60000 when 'coolant' then 100000 end;
  elsif v like '%mercedes%' or v like '%benz%' then
    return case p_service_type when 'oil_change' then 10000 when 'tire_service' then 10000
      when 'transmission_service' then 60000 when 'spark_plugs' then 60000 when 'coolant' then 100000 end;
  elsif v like '%cadillac%ats%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 45000 when 'spark_plugs' then 97000 when 'coolant' then 150000 end;
  elsif v like '%dodge%van%' then
    return case p_service_type when 'oil_change' then 7500 when 'tire_service' then 7500
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  elsif v like '%ford%f350%' or v like '%ford%f-350%' then
    return case p_service_type when 'oil_change' then 5000 when 'tire_service' then 5000
      when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
  end if;

  return case p_service_type when 'oil_change' then 5000 when 'tire_service' then 7500
    when 'transmission_service' then 60000 when 'spark_plugs' then 100000 when 'coolant' then 100000 end;
end;
$$;

create or replace function public.rentmect_oem_month_interval(
  p_vehicle text,
  p_service_type text
) returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := lower(coalesce(p_vehicle, ''));
begin
  if p_service_type <> 'brake_fluid' then return null; end if;
  if v like '%kia%soul%' then return 60; end if;
  if v ~ '(^|[^a-z])audi([^a-z]|$)' or v like '%bmw%' or v like '%mercedes%' or v like '%benz%' then return 24; end if;
  return 36;
end;
$$;
