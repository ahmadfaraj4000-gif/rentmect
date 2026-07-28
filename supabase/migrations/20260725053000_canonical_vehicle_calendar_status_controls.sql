-- Keep rental schedule states system-owned and limit admin calendar writes to
-- explicit operational blocks. Existing legacy Reserved / On the Road blocks
-- remain blocked, but become editable Admin Hold records.

do $$
declare
  v_unknown_types text;
begin
  select string_agg(distinct lower(btrim(block_type)), ', ' order by lower(btrim(block_type)))
    into v_unknown_types
  from public.vehicle_availability_blocks
  where lower(btrim(block_type)) not in (
    'available',
    'unavailable',
    'maintenance',
    'admin_hold',
    'extension_hold',
    'reserved',
    'on_road'
  );

  if v_unknown_types is not null then
    raise exception
      'Cannot install calendar status guardrail until these unexpected block types are reviewed: %',
      v_unknown_types;
  end if;
end;
$$;

update public.vehicle_availability_blocks
set
  block_type = case
    when lower(btrim(block_type)) in ('reserved', 'on_road') then 'admin_hold'
    else lower(btrim(block_type))
  end,
  label = case
    when lower(btrim(block_type)) in ('reserved', 'on_road')
      and lower(btrim(label)) in ('reserved', 'on the road', 'on road')
      then 'Admin Hold'
    else label
  end,
  updated_at = now()
where block_type is distinct from lower(btrim(block_type))
   or lower(btrim(block_type)) in ('reserved', 'on_road');

alter table public.vehicle_availability_blocks
  drop constraint if exists vehicle_availability_blocks_block_type_check;

alter table public.vehicle_availability_blocks
  add constraint vehicle_availability_blocks_block_type_check
  check (block_type in ('available', 'unavailable', 'maintenance', 'admin_hold', 'extension_hold'));

alter table public.vehicle_availability_blocks
  drop constraint if exists vehicle_availability_blocks_extension_hold_marker_check;

alter table public.vehicle_availability_blocks
  add constraint vehicle_availability_blocks_extension_hold_marker_check
  check (
    block_type <> 'extension_hold'
    or coalesce(notes, '') ~ '\[EXTENSION_REQUEST=[0-9a-fA-F-]{36}\]'
  );

notify pgrst, 'reload schema';
