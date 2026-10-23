-- Run against an isolated migrated database. All rows/settings roll back.
begin;
do $$
declare
  rid uuid := gen_random_uuid();
  start_at timestamptz := '2026-10-22 14:00:00-04';
  due_at timestamptz := '2026-11-21 14:00:00-05';
  actual timestamptz;
begin
  assert (select deposit_release_delay_days=30 and automatic_deposit_release_enabled from public.billing_automation_settings where id=true), 'Migration must enable 30-day scheduling';
  -- This isolated fixture deliberately exercises the production trigger functions
  -- without unrelated customer/payment/vehicle constraints.
  create temporary table deposit_schedule_probe (
    id uuid, status text, payment_provider text, deposit_status text,
    return_initiated_at timestamptz, inspection_completed_at timestamptz,
    deposit_release_due_at timestamptz, deposit_release_reason text, deposit_release_error text
  );
  create trigger schedule_probe before update on deposit_schedule_probe for each row execute function public.schedule_rentmect_deposit_release();
  insert into deposit_schedule_probe(id,status,payment_provider,deposit_status,return_initiated_at,inspection_completed_at)
    values(rid,'return_initiated','stripe','held',start_at,start_at + interval '1 day');
  update deposit_schedule_probe set status='completed' where id=rid;
  select deposit_release_due_at into actual from deposit_schedule_probe where id=rid;
  assert actual=due_at, format('Expected 30 Eastern calendar days across DST, got %s',actual);
  update deposit_schedule_probe set deposit_status='released' where id=rid;
  assert (select deposit_release_due_at is null from deposit_schedule_probe where id=rid), 'Manual early release must clear the deadline';
  update deposit_schedule_probe set status='active',deposit_status='held',return_initiated_at=null,inspection_completed_at=start_at where id=rid;
  update deposit_schedule_probe set status='completed' where id=rid;
  assert (select deposit_release_due_at=due_at from deposit_schedule_probe where id=rid), 'Inspection timestamp is the fallback when no customer dropoff exists';
  update deposit_schedule_probe set status='active',payment_provider='local',deposit_release_due_at=null where id=rid;
  update deposit_schedule_probe set status='completed' where id=rid;
  assert (select deposit_release_due_at is null from deposit_schedule_probe where id=rid), 'External deposits cannot be sent to Stripe';
end $$;
rollback;
