-- Removes the retired early-availability markers. Rental turnaround is always
-- return time plus three hours in both the calendar and booking functions.
-- Run this before rerunning admin_manual_booking.sql and
-- client_portal_calendar_source_of_truth.sql.

update public.rentals
set admin_notes = nullif(
  btrim(
    regexp_replace(
      regexp_replace(coalesce(admin_notes, ''), '\[TURNAROUND_AVAILABLE_AT=[^\]]+\]', '', 'g'),
      '\[TURNAROUND_GRACE_CONFIRMED_RETURNED\]',
      '',
      'g'
    )
  ),
  ''
)
where coalesce(admin_notes, '') ~ '\[TURNAROUND_(AVAILABLE_AT|GRACE_CONFIRMED_RETURNED)';

update public.vehicle_availability_blocks
set notes = nullif(
  btrim(
    regexp_replace(
      regexp_replace(coalesce(notes, ''), '\[TURNAROUND_AVAILABLE_AT=[^\]]+\]', '', 'g'),
      '\[TURNAROUND_GRACE_CONFIRMED_RETURNED\]',
      '',
      'g'
    )
  ),
  ''
)
where coalesce(notes, '') ~ '\[TURNAROUND_(AVAILABLE_AT|GRACE_CONFIRMED_RETURNED)';
