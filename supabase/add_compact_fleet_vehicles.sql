insert into public.vehicles (
  id,
  name,
  brand,
  model,
  vehicle_type,
  daily_rate,
  security_deposit,
  status
)
values
  (
    '790137a1-2b04-4169-9027-3a610a8f7d27',
    'Buick Encore #649',
    'Buick',
    'Encore',
    'Compact SUV',
    49,
    300,
    'available'
  ),
  (
    '3a27aa73-3c1e-4b4e-bf55-cfbb09e59bf3',
    'Ford Escape #650',
    'Ford',
    'Escape',
    'Compact SUV',
    49,
    300,
    'available'
  ),
  (
    'a3e97226-347e-4154-905c-3c8c22613600',
    'Kia Soul #656',
    'Kia',
    'Soul',
    'Compact Hatchback',
    49,
    300,
    'available'
  )
on conflict (id) do update
set
  name = excluded.name,
  brand = excluded.brand,
  model = excluded.model,
  vehicle_type = excluded.vehicle_type,
  daily_rate = excluded.daily_rate,
  security_deposit = excluded.security_deposit,
  status = excluded.status;
