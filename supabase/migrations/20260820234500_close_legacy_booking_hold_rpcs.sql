-- Deploy only after every production booking surface has been verified against
-- the protected website-booking-hold Edge Function.

revoke all on function public.create_website_pending_booking(date, date, text, text, uuid, text)
  from public, anon, authenticated;
revoke all on function public.create_website_pending_booking_with_token(date, date, text, text, uuid, text)
  from public, anon, authenticated;

grant execute on function public.create_website_pending_booking(date, date, text, text, uuid, text)
  to service_role;
grant execute on function public.create_website_pending_booking_with_token(date, date, text, text, uuid, text)
  to service_role;
