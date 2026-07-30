-- Make the Supabase vehicle record the customer/admin source of truth for
-- features and pictures used by cars-2.html.

with catalog(fleet_number, asset_slug, features) as (
  values
    ('001', 'Audi-S3-001', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('002', 'Audi-A4-002', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('004', 'BMW-328I-004', array['AUX input','Backup camera','Bluetooth','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('100', 'Audi-Q3-100', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('148', 'Audi-Q5-148', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('149', 'Audi-Q5-149', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB charger','USB input']::text[]),
    ('157', 'BMW-330I-157', array['Apple CarPlay','AUX input','Backup camera','Bluetooth','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('158', 'Audi-A4-158', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('166', 'BMW-330XI-166', array['Apple CarPlay','AUX input','Backup camera','Bluetooth','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('191', 'Ford-F350-4X4-191', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','USB input']::text[]),
    ('203', 'Audi-Q5-203', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof']::text[]),
    ('210', 'Audi-Q5-210', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('224', 'Benz-CLS-AMG-550-224', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('225', 'Audi-Q5-225', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('234', 'Audi-Q5-234', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('321', 'Mercedes-C300-321', array['AUX input','Bluetooth','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('385', 'Audi-A6-385', array['Android Auto','Apple CarPlay','AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('418', 'Benz-C300-418', array['Android Auto','Apple CarPlay','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('451', 'Dodge-Van-451', array['AUX input','Backup camera','Bluetooth','Keyless entry','USB input']::text[]),
    ('452', 'Dodge-Van-452', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','USB input']::text[]),
    ('473', 'Audi-A6-473', array['Android Auto','Apple CarPlay','AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('474', 'Audi-Q5-474', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('649', 'Buick-Encore-649', array['Android Auto','Apple CarPlay','AUX input','Backup camera','Bluetooth','Heated seats','Keyless entry','USB input']::text[]),
    ('650', 'Ford-Escape-650', array['Android Auto','Apple CarPlay','Backup camera','Bluetooth','Keyless entry','USB input']::text[]),
    ('656', 'Kia-Soul-656', array['Android Auto','Apple CarPlay','Backup camera','Bluetooth','USB input']::text[]),
    ('677', 'Mercedes-Benz-C300-677', array['Android Auto','Apple CarPlay','AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('780', 'Cadillac-ATS-780', array['AUX input','Backup camera','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('997', 'Audi-Q5-997', array['Android Auto','Apple CarPlay','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','Sunroof','USB input']::text[]),
    ('YPS', 'Audi-A8L-YPS', array['AUX input','Backup camera','Blind spot warning','Bluetooth','GPS','Heated seats','Keyless entry','USB input']::text[])
),
gallery_jpg(image_key) as (
  values
    ('001-2'), ('002-1'), ('002-2'), ('100-3'), ('148-1'), ('157-2'),
    ('191-1'), ('191-2'), ('210-1'), ('210-2'), ('225-2'), ('321-1'),
    ('451-2'), ('474-1'), ('649-2'), ('656-1'), ('656-2'), ('656-3')
),
resolved as (
  select
    c.fleet_number,
    c.features,
    array['https://rentmect.com/assets/' || c.asset_slug || '.webp']
      || array(
        select
          'https://rentmect.com/assets/fleet-2/' || c.fleet_number || '-' || image_index
            || case when jpg.image_key is null then '.webp' else '.jpg' end
        from generate_series(1, 4) image_index
        left join gallery_jpg jpg
          on jpg.image_key = c.fleet_number || '-' || image_index
        order by image_index
      ) as image_urls
  from catalog c
)
update public.vehicles vehicle
set
  features = resolved.features,
  image_urls = resolved.image_urls,
  image_url = resolved.image_urls[1],
  updated_at = now()
from resolved
where upper(substring(vehicle.name from '#([[:alnum:]]+)$')) = resolved.fleet_number;

do $$
declare
  v_missing text[];
begin
  select array_agg(name order by name)
  into v_missing
  from public.vehicles
  where published is true
    and id <> '00000000-0000-4000-8000-000000000015'::uuid
    and (
      coalesce(cardinality(features), 0) < 3
      or coalesce(cardinality(image_urls), 0) < 1
    );

  if coalesce(cardinality(v_missing), 0) > 0 then
    raise exception 'Published vehicle catalog backfill is incomplete: %', array_to_string(v_missing, ', ');
  end if;
end;
$$;

alter table public.vehicles
  drop constraint if exists vehicles_published_catalog_complete;

alter table public.vehicles
  add constraint vehicles_published_catalog_complete
  check (
    published is not true
    or (
      coalesce(cardinality(features), 0) >= 3
      and coalesce(cardinality(image_urls), 0) >= 1
    )
  ) not valid;

alter table public.vehicles
  validate constraint vehicles_published_catalog_complete;

comment on constraint vehicles_published_catalog_complete on public.vehicles is
  'Published cars-2 listings must have at least three customer features and one admin-managed picture.';
