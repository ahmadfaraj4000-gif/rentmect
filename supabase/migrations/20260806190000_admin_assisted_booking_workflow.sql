begin;

-- Admin-assisted bookings use durable, audited completions instead of temporary
-- emergency exceptions. Customer self-service continues to use the native
-- verification, document, agreement, and payment records.
alter table public.booking_policy_settings
  add column if not exists admin_booking_payment_deadline_minutes integer not null default 60
    check (admin_booking_payment_deadline_minutes between 5 and 10080);

alter table public.profiles
  add column if not exists identity_verification_method text,
  add column if not exists identity_verified_by uuid references auth.users(id) on delete set null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_identity_verification_method_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_identity_verification_method_check
      check (identity_verification_method is null or identity_verification_method in ('stripe', 'admin_in_person'));
  end if;
end;
$$;

update public.profiles
set identity_verification_method = 'stripe'
where identity_verification_status = 'verified'
  and identity_verification_method is null;

create table if not exists public.rental_step_completions (
  id uuid primary key default gen_random_uuid(),
  rental_id uuid not null references public.rentals(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  step_key text not null check (step_key in ('phone','identity','license','insurance','agreement','payment','deposit')),
  completion_source text not null check (completion_source in (
    'admin_in_person','admin_document_review','admin_office_signature',
    'admin_external_payment','admin_deposit_collected','admin_deposit_waived'
  )),
  note text not null check (length(trim(note)) >= 5),
  metadata jsonb not null default '{}'::jsonb,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (rental_id, step_key)
);

create index if not exists rental_step_completions_rental_idx
  on public.rental_step_completions (rental_id, completed_at desc);

alter table public.rental_step_completions enable row level security;
revoke all on public.rental_step_completions from anon, authenticated;
grant select on public.rental_step_completions to authenticated;
grant all on public.rental_step_completions to service_role;

drop policy if exists "Admins can read rental step completions" on public.rental_step_completions;
create policy "Admins can read rental step completions"
on public.rental_step_completions for select to authenticated
using (public.is_admin());

drop function if exists public.get_admin_booking_policy();
create or replace function public.get_admin_booking_policy()
returns table (
  minimum_rental_days integer,
  minimum_rental_hours integer,
  advance_notice_minutes integer,
  admin_booking_payment_deadline_minutes integer,
  updated_by uuid,
  updated_at timestamptz,
  server_now timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'Admin access required.'; end if;
  return query
  select settings.minimum_rental_days,
         settings.minimum_rental_days * 24,
         settings.advance_notice_minutes,
         settings.admin_booking_payment_deadline_minutes,
         settings.updated_by,
         settings.updated_at,
         now()
  from public.booking_policy_settings settings where settings.id = true;
end;
$$;

drop function if exists public.set_admin_booking_policy(integer, integer);
create or replace function public.set_admin_booking_policy(
  p_minimum_rental_days integer,
  p_advance_notice_minutes integer,
  p_admin_booking_payment_deadline_minutes integer
) returns public.booking_policy_settings
language plpgsql security definer set search_path = public
as $$
declare
  v_previous public.booking_policy_settings%rowtype;
  v_updated public.booking_policy_settings%rowtype;
begin
  if not public.is_admin() then raise exception 'Admin access required.'; end if;
  if p_minimum_rental_days is null or p_minimum_rental_days < 1 or p_minimum_rental_days > 30 then
    raise exception 'Minimum rental duration must be between 1 and 30 days.';
  end if;
  if p_advance_notice_minutes is null or p_advance_notice_minutes < 0 or p_advance_notice_minutes > 525600 then
    raise exception 'Advance notice must be between immediate and 365 days.';
  end if;
  if p_admin_booking_payment_deadline_minutes is null
     or p_admin_booking_payment_deadline_minutes < 5
     or p_admin_booking_payment_deadline_minutes > 10080 then
    raise exception 'Admin booking payment deadline must be between 5 minutes and 7 days.';
  end if;

  select * into v_previous from public.booking_policy_settings where id = true for update;
  update public.booking_policy_settings
  set minimum_rental_days = p_minimum_rental_days,
      advance_notice_minutes = p_advance_notice_minutes,
      admin_booking_payment_deadline_minutes = p_admin_booking_payment_deadline_minutes,
      updated_by = auth.uid(), updated_at = now()
  where id = true returning * into v_updated;

  perform public.record_admin_audit_event(
    'booking_policy.updated', 'booking_policy', 'global',
    jsonb_build_object(
      'old_minimum_rental_days', v_previous.minimum_rental_days,
      'new_minimum_rental_days', v_updated.minimum_rental_days,
      'old_advance_notice_minutes', v_previous.advance_notice_minutes,
      'new_advance_notice_minutes', v_updated.advance_notice_minutes,
      'old_admin_booking_payment_deadline_minutes', v_previous.admin_booking_payment_deadline_minutes,
      'new_admin_booking_payment_deadline_minutes', v_updated.admin_booking_payment_deadline_minutes
    )
  );
  return v_updated;
end;
$$;

revoke all on function public.set_admin_booking_policy(integer, integer, integer) from public;
grant execute on function public.set_admin_booking_policy(integer, integer, integer) to authenticated;

create or replace function public.initialize_rental_lifecycle()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_admin_deadline_minutes integer := 60;
begin
  if tg_op = 'INSERT' then
    if public.is_admin() and new.source_pending_booking_id is null then
      new.booking_source := 'admin_manual';
    elsif coalesce(new.booking_source, '') = '' then
      new.booking_source := 'customer_portal';
    end if;

    if coalesce(lower(new.payment_status), 'pending') <> 'paid' then
      if new.booking_source = 'admin_manual' then
        select settings.admin_booking_payment_deadline_minutes
        into v_admin_deadline_minutes
        from public.booking_policy_settings settings where settings.id = true;
        v_admin_deadline_minutes := coalesce(v_admin_deadline_minutes, 60);
        new.payment_due_at := coalesce(new.payment_due_at, now() + make_interval(mins => v_admin_deadline_minutes));
        new.checkout_expires_at := null;
      else
        new.checkout_expires_at := coalesce(new.checkout_expires_at, now() + interval '25 minutes');
        new.payment_due_at := coalesce(new.payment_due_at, new.checkout_expires_at);
      end if;
    end if;
  end if;

  if coalesce(lower(new.payment_status), 'pending') = 'paid' then
    new.checkout_expires_at := null;
    new.payment_due_at := null;
  end if;
  if tg_op = 'UPDATE' and lower(coalesce(new.status, '')) = 'cancelled'
     and lower(coalesce(old.status, '')) <> 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;
  return new;
end;
$$;

create or replace function public.admin_extend_rental_payment_deadline(
  p_rental_id uuid, p_payment_due_at timestamptz, p_reason text
) returns public.rentals
language plpgsql security definer set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_payment_due_at is null or p_payment_due_at <= now() then raise exception 'Choose a future payment deadline.'; end if;
  if p_payment_due_at > now() + interval '30 days' then raise exception 'An individual payment deadline cannot exceed 30 days.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Enter a reason for changing the deadline.'; end if;

  update public.rentals
  set payment_due_at = p_payment_due_at,
      checkout_expires_at = case when booking_source = 'admin_manual' then null else p_payment_due_at end,
      updated_at = now()
  where id = p_rental_id
    and coalesce(lower(payment_status), 'pending') <> 'paid'
    and lower(coalesce(status, '')) not in ('cancelled','completed','active','overdue','return_initiated')
  returning * into v_rental;
  if not found then raise exception 'Only an open unpaid reservation can have its deadline changed.'; end if;

  insert into public.rental_audit_events (rental_id,user_id,actor_id,event_type,event_payload)
  values (v_rental.id,v_rental.user_id,v_admin_id,'admin_payment_deadline_changed',
    jsonb_build_object('payment_due_at',p_payment_due_at,'reason',trim(p_reason)));
  return v_rental;
end;
$$;

create or replace function public.rentmect_rental_requirement_complete(p_rental_id uuid, p_scope text)
returns boolean language plpgsql security definer stable set search_path = public
as $$
declare
  v_rental public.rentals%rowtype;
begin
  select * into v_rental from public.rentals where id = p_rental_id;
  if not found then return false; end if;
  if exists (select 1 from public.rental_step_completions c where c.rental_id = p_rental_id and c.step_key = p_scope) then
    return true;
  end if;
  case p_scope
    when 'phone' then return exists (select 1 from public.profiles where id=v_rental.user_id and coalesce(phone_verified,false));
    when 'identity' then return public.rentmect_identity_is_verified(v_rental.user_id);
    when 'agreement' then return coalesce(v_rental.agreement_signed,false);
    when 'payment' then return lower(coalesce(v_rental.payment_status,''))='paid';
    when 'deposit' then return coalesce(v_rental.security_deposit,0)=0 or lower(coalesce(v_rental.deposit_status,'')) in ('held','waived','released','transferred','release_pending','adjustment_refund_due');
    when 'license' then return coalesce((select lower(coalesce(d.status,''))='approved' from public.rental_documents d where d.user_id=v_rental.user_id and d.document_type='license' order by d.created_at desc nulls last,d.id desc limit 1),false);
    when 'insurance' then return coalesce((select lower(coalesce(d.status,''))='approved' from public.rental_documents d where d.rental_id=v_rental.id and d.user_id=v_rental.user_id and d.document_type='insurance' order by d.created_at desc nulls last,d.id desc limit 1),false);
    else return false;
  end case;
end;
$$;

create or replace function public.sync_rental_ready_for_pickup_global(p_rental_id uuid)
returns public.rentals language plpgsql security definer set search_path = public
as $$
declare v_rental public.rentals%rowtype;
begin
  select * into v_rental from public.rentals where id=p_rental_id for update;
  if not found then return null; end if;
  if lower(coalesce(v_rental.status,'')) not in ('pending','documents_needed','document_review','approved') then return v_rental; end if;
  if not public.rentmect_rental_requirement_complete(v_rental.id,'phone')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'identity')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'license')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'insurance')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'agreement')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'payment')
     or not public.rentmect_rental_requirement_complete(v_rental.id,'deposit') then return v_rental; end if;
  update public.rentals set status='ready_for_pickup',updated_at=now() where id=v_rental.id returning * into v_rental;
  update public.vehicles set status='reserved' where id=v_rental.vehicle_id and coalesce(lower(status),'available') not in ('maintenance','unavailable','inactive');
  insert into public.rental_audit_events (rental_id,user_id,actor_id,event_type,event_payload)
  values (v_rental.id,v_rental.user_id,auth.uid(),'rental_auto_ready_for_pickup',jsonb_build_object('source','admin_assisted_completion'));
  return v_rental;
end;
$$;

create or replace function public.admin_complete_rental_step(
  p_rental_id uuid,
  p_step_key text,
  p_note text,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_completion public.rental_step_completions%rowtype;
  v_source text := 'admin_in_person';
  v_deposit_disposition text;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if p_step_key not in ('phone','identity','license','insurance','deposit') then raise exception 'This step uses its dedicated completion action.'; end if;
  if length(trim(coalesce(p_note,''))) < 5 then raise exception 'Add a short completion note (at least 5 characters).'; end if;
  select * into v_rental from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status,'')) in ('cancelled','completed') then raise exception 'Closed rentals cannot be changed.'; end if;

  if p_step_key='phone' then
    update public.profiles set phone_verified=true,phone_verified_at=coalesce(phone_verified_at,now()) where id=v_rental.user_id;
  elsif p_step_key='identity' then
    update public.profiles set identity_verification_status='verified',identity_verified_at=now(),identity_verification_updated_at=now(),identity_verification_method='admin_in_person',identity_verified_by=v_admin_id where id=v_rental.user_id;
  elsif p_step_key in ('license','insurance') then
    v_source := 'admin_document_review';
    update public.rental_documents d set status='approved'
    where d.id=(select latest.id from public.rental_documents latest where latest.user_id=v_rental.user_id and latest.document_type=p_step_key and (p_step_key='license' or latest.rental_id=v_rental.id) order by latest.created_at desc nulls last,latest.id desc limit 1);
  elsif p_step_key='deposit' then
    v_deposit_disposition := lower(coalesce(p_metadata->>'disposition','collected'));
    if v_deposit_disposition='waived' then
      if lower(coalesce(v_rental.payment_status,'pending'))='paid' and coalesce(v_rental.security_deposit,0)>0 then raise exception 'A captured deposit must be refunded, not marked waived.'; end if;
      update public.rentals set security_deposit=0,deposit_held_amount=0,deposit_status='waived',updated_at=now() where id=v_rental.id;
      v_source := 'admin_deposit_waived';
    elsif v_deposit_disposition='collected' then
      update public.rentals set deposit_held_amount=greatest(coalesce(deposit_held_amount,0),coalesce(security_deposit,0)),deposit_status=case when coalesce(security_deposit,0)>0 then 'held' else 'waived' end,updated_at=now() where id=v_rental.id;
      v_source := 'admin_deposit_collected';
    else raise exception 'Choose collected or waived for the deposit.';
    end if;
  end if;

  insert into public.rental_step_completions (rental_id,user_id,step_key,completion_source,note,metadata,completed_by)
  values (v_rental.id,v_rental.user_id,p_step_key,v_source,trim(p_note),coalesce(p_metadata,'{}'::jsonb),v_admin_id)
  on conflict (rental_id,step_key) do update set completion_source=excluded.completion_source,note=excluded.note,metadata=excluded.metadata,completed_by=excluded.completed_by,completed_at=now(),updated_at=now()
  returning * into v_completion;

  insert into public.rental_audit_events (rental_id,user_id,actor_id,event_type,event_payload)
  values (v_rental.id,v_rental.user_id,v_admin_id,'admin_booking_step_completed',jsonb_build_object('step',p_step_key,'source',v_source,'note',trim(p_note),'metadata',coalesce(p_metadata,'{}'::jsonb)));
  v_rental := public.sync_rental_ready_for_pickup_global(v_rental.id);
  return jsonb_build_object('rental',to_jsonb(v_rental),'completion',to_jsonb(v_completion));
end;
$$;

revoke all on function public.admin_complete_rental_step(uuid,text,text,jsonb) from public;
grant execute on function public.admin_complete_rental_step(uuid,text,text,jsonb) to authenticated;

create or replace function public.admin_sign_rental_agreement_in_office(
  p_rental_id uuid,
  p_signature_name text,
  p_agreement_version text,
  p_agreement_snapshot text,
  p_agreement_hash text,
  p_signature_data text,
  p_note text
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_admin_id uuid := auth.uid();
  v_rental public.rentals%rowtype;
  v_completion public.rental_step_completions%rowtype;
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required.'; end if;
  if length(trim(coalesce(p_signature_name,'')))<2 then raise exception 'The customer full legal signature is required.'; end if;
  if coalesce(p_signature_data,'') not like 'data:image/png;base64,%' then raise exception 'Draw the customer signature before saving.'; end if;
  if length(trim(coalesce(p_note,'')))<5 then raise exception 'Add a short in-office signing note.'; end if;
  select * into v_rental from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;

  insert into public.rental_signatures (user_id,rental_id,signature_name,signature_data,agreement_version,agreement_snapshot,agreement_hash,user_agent,vehicle_id,rental_total,tax_amount,security_deposit,mileage_policy,signed_at)
  values (v_rental.user_id,v_rental.id,trim(p_signature_name),p_signature_data,p_agreement_version,p_agreement_snapshot,p_agreement_hash,'Admin portal — customer signed in office',v_rental.vehicle_id,v_rental.rental_total,v_rental.tax_amount,v_rental.security_deposit,coalesce(v_rental.mileage_policy,'200 miles/day included; excess mileage $0.35/mile'),now());

  update public.rentals set agreement_signed=true,agreement_version=p_agreement_version,agreement_snapshot=p_agreement_snapshot,agreement_hash=p_agreement_hash,agreement_signed_at=now(),agreement_signature_name=trim(p_signature_name),agreement_user_agent='Admin portal — customer signed in office',updated_at=now() where id=v_rental.id returning * into v_rental;
  insert into public.rental_step_completions (rental_id,user_id,step_key,completion_source,note,metadata,completed_by)
  values (v_rental.id,v_rental.user_id,'agreement','admin_office_signature',trim(p_note),jsonb_build_object('agreement_version',p_agreement_version,'agreement_hash',p_agreement_hash,'customer_present',true),v_admin_id)
  on conflict (rental_id,step_key) do update set completion_source=excluded.completion_source,note=excluded.note,metadata=excluded.metadata,completed_by=excluded.completed_by,completed_at=now(),updated_at=now()
  returning * into v_completion;
  insert into public.rental_audit_events (rental_id,user_id,actor_id,event_type,event_payload)
  values (v_rental.id,v_rental.user_id,v_admin_id,'agreement_signed_in_office',jsonb_build_object('agreement_version',p_agreement_version,'agreement_hash',p_agreement_hash,'signature_name',trim(p_signature_name),'customer_present',true));
  v_rental := public.sync_rental_ready_for_pickup_global(v_rental.id);
  return jsonb_build_object('rental',to_jsonb(v_rental),'completion',to_jsonb(v_completion));
end;
$$;

revoke all on function public.admin_sign_rental_agreement_in_office(uuid,text,text,text,text,text,text) from public;
grant execute on function public.admin_sign_rental_agreement_in_office(uuid,text,text,text,text,text,text) to authenticated;

-- External payment records are proof of actual collection and may be entered
-- before the assisted verification steps. Pickup remains guarded until every
-- step is complete.
create or replace function public.record_admin_local_rental_payment(p_rental_id uuid,p_amount numeric,p_payment_method text)
returns public.rentals language plpgsql security definer set search_path = public
as $$
declare
  v_admin_id uuid:=auth.uid(); v_rental public.rentals%rowtype; v_amount_due numeric(12,2); v_amount_received numeric(12,2); v_payment_method text:=lower(trim(coalesce(p_payment_method,'')));
begin
  if v_admin_id is null or not public.is_admin() then raise exception 'Admin access is required to record an external payment.'; end if;
  if v_payment_method not in ('card','cash_app','cash') then raise exception 'Choose Card, Cash App, or Cash.'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Enter the actual external payment amount received.'; end if;
  select * into v_rental from public.rentals where id=p_rental_id for update;
  if not found then raise exception 'Rental not found.'; end if;
  if lower(coalesce(v_rental.status,''))='cancelled' then raise exception 'Cancelled rentals cannot be marked paid.'; end if;
  if lower(coalesce(v_rental.payment_status,'pending'))='paid' then raise exception 'This rental is already paid.'; end if;
  v_amount_due:=round(coalesce(v_rental.rental_total,0)+coalesce(v_rental.service_fee_total,0)+coalesce(v_rental.tax_amount,0)+coalesce(v_rental.security_deposit,0),2);
  v_amount_received:=round(p_amount,2);
  if v_amount_received<>v_amount_due then raise exception 'The external payment must equal the full amount due: $%.',to_char(v_amount_due,'FM999999990.00'); end if;
  update public.rentals set payment_status='paid',deposit_status=case when coalesce(security_deposit,0)>0 then 'held' else 'waived' end,payment_provider='local',payment_amount_cents=round(v_amount_received*100)::integer,paid_at=coalesce(paid_at,now()),external_payment_amount=v_amount_received,external_payment_method=v_payment_method,external_payment_recorded_at=now(),external_payment_recorded_by=v_admin_id,deposit_held_amount=greatest(coalesce(deposit_held_amount,0),coalesce(security_deposit,0)),updated_at=now() where id=p_rental_id returning * into v_rental;
  update public.rental_charge_items set status='paid',payment_provider='local',paid_at=coalesce(paid_at,now()),updated_at=now() where rental_id=v_rental.id and included_in_initial_payment and status<>'paid';
  perform public.ensure_rental_deposit_allocation(v_rental.id);
  insert into public.rental_step_completions (rental_id,user_id,step_key,completion_source,note,metadata,completed_by)
  values (v_rental.id,v_rental.user_id,'payment','admin_external_payment','Payment collected and recorded by admin.',jsonb_build_object('amount',v_amount_received,'payment_method',v_payment_method),v_admin_id)
  on conflict (rental_id,step_key) do update set completion_source=excluded.completion_source,note=excluded.note,metadata=excluded.metadata,completed_by=excluded.completed_by,completed_at=now(),updated_at=now();
  insert into public.rental_step_completions (rental_id,user_id,step_key,completion_source,note,metadata,completed_by)
  values (v_rental.id,v_rental.user_id,'deposit','admin_deposit_collected','Deposit included in external payment.',jsonb_build_object('amount',coalesce(v_rental.security_deposit,0)),v_admin_id)
  on conflict (rental_id,step_key) do update set completion_source=excluded.completion_source,note=excluded.note,metadata=excluded.metadata,completed_by=excluded.completed_by,completed_at=now(),updated_at=now();
  insert into public.rental_audit_events (rental_id,user_id,actor_id,event_type,event_payload) values (v_rental.id,v_rental.user_id,v_admin_id,'admin_local_payment_recorded',jsonb_build_object('source','record_admin_local_rental_payment','amount',v_amount_received,'payment_method',v_payment_method,'assisted_booking',true));
  update public.vehicles set status='reserved' where id=v_rental.vehicle_id and coalesce(lower(status),'available') not in ('maintenance','unavailable','inactive');
  v_rental:=public.sync_rental_ready_for_pickup_global(v_rental.id);
  return v_rental;
end;
$$;

revoke all on function public.record_admin_local_rental_payment(uuid,numeric,text) from public;
grant execute on function public.record_admin_local_rental_payment(uuid,numeric,text) to authenticated;

notify pgrst, 'reload schema';
commit;
