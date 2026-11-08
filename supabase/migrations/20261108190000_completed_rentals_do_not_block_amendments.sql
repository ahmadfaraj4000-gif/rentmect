-- Match the live scheduling guard: a completed rental releases its reservation.
-- Preserve the existing overlap, turnaround, calendar, pricing and audit checks.
do $migration$
declare
  definition text;
  old_filter text := $old$and lower(coalesce(rentals.status, '')) <> 'cancelled'$old$;
  new_filter text := $new$and lower(coalesce(rentals.status, '')) not in ('completed', 'cancelled')$new$;
begin
  select pg_get_functiondef('public.admin_preview_rental_amendment_without_manual_discount(uuid,uuid,date,text,date,text,numeric,numeric)'::regprocedure)
    into definition;
  if position(new_filter in definition) > 0 and position(old_filter in definition) = 0 then
    return;
  end if;
  if (length(definition) - length(replace(definition, old_filter, ''))) / length(old_filter) <> 1 then
    raise exception 'Rental amendment schedule guard changed; review before migrating.';
  end if;
  execute replace(definition, old_filter, new_filter);
end;
$migration$;
