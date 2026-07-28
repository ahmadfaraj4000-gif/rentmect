-- Restore the report-to-customer relationship used by the admin portal.
-- Abort before changing the constraint if legacy report rows reference a
-- profile that no longer exists.

do $$
declare
  orphaned_report_count bigint;
begin
  select count(*)
    into orphaned_report_count
  from public.vehicle_reports as report
  left join public.profiles as profile
    on profile.id = report.user_id
  where report.user_id is not null
    and profile.id is null;

  if orphaned_report_count > 0 then
    raise exception
      'Cannot restore vehicle_reports_user_id_fkey: % orphaned vehicle report user_id value(s) require cleanup.',
      orphaned_report_count;
  end if;
end
$$;

alter table public.vehicle_reports
  drop constraint if exists vehicle_reports_user_id_fkey;

alter table public.vehicle_reports
  add constraint vehicle_reports_user_id_fkey
  foreign key (user_id)
  references public.profiles(id)
  on delete set null;

notify pgrst, 'reload schema';
