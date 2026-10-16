-- Synthetic fixture only. Called inside isolated, rolled-back regression tests.
create function pg_temp.ticket_account_fixture(p_deposit numeric default 300,p_paid numeric default 0)
returns uuid language plpgsql as $$
declare rid uuid; customer uuid:=gen_random_uuid(); car uuid;
begin
  perform set_config('session_replication_role','replica',true);
  insert into auth.users(id) values('11111111-1111-4111-8111-111111111111'),(customer) on conflict do nothing;
  insert into public.profiles(id,role,staff_role,date_of_birth)
    values('11111111-1111-4111-8111-111111111111','admin','owner','1980-01-01'),
    (customer,'customer','customer','1980-01-01') on conflict do nothing;
  insert into public.vehicles(name,daily_rate,security_deposit,status,is_active,published)
    values('Synthetic audit vehicle',69,p_deposit,'available',true,false) returning id into car;
  insert into public.rentals(user_id,vehicle_id,pickup_date,pickup_time,return_date,return_time,status,
    rental_total,base_rental_total,tax_amount,security_deposit,deposit_held_amount,deposit_status,
    payment_status,paid_at,payment_amount_cents,payment_provider,starting_mileage,agreement_signed)
    values(customer,car,current_date-7,'9:00 AM',current_date,'9:00 AM','active',483,483,30.67,
      p_deposit,case when p_paid>0 then p_deposit else 0 end,case when p_paid>0 then 'held' else 'pending' end,
      case when p_paid=513.67+p_deposit then 'paid' when p_paid>0 then 'partially_paid' else 'pending' end,
      case when p_paid>0 then now() else null end,case when p_paid>0 then round(p_paid*100)::integer else null end,
      case when p_paid>0 then 'stripe' else null end,1000,true) returning id into rid;
  insert into public.rental_vehicle_assignments(rental_id,vehicle_id,assigned_from,assigned_until,source)
    values(rid,car,public.rentmect_rental_timestamp(current_date-7,'9:00 AM') at time zone 'America/New_York',
      public.rentmect_rental_timestamp(current_date,'9:00 AM') at time zone 'America/New_York','initial');
  perform set_config('session_replication_role','origin',true);
  return rid;
end; $$;
