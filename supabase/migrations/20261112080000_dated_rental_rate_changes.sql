begin;
set local lock_timeout='5s';
create table public.rental_rate_changes (
 id uuid primary key, rental_id uuid not null references public.rentals(id), actor_id uuid not null references public.profiles(id),
 effective_at timestamptz not null, daily_rate numeric not null, reason text not null,
 request jsonb not null, financial_effect jsonb not null, created_at timestamptz not null default now()
);
alter table public.rental_rate_changes enable row level security;
create policy rate_changes_staff_read on public.rental_rate_changes for select to authenticated
 using(public.rentmect_has_permission('rental.edit'));
grant select on public.rental_rate_changes to authenticated;
alter table public.rental_pricing_periods drop constraint rental_pricing_periods_source_check;
alter table public.rental_pricing_periods add constraint rental_pricing_periods_source_check check(source in ('booking_snapshot','swap','extension','rate_change'));

create function public.admin_preview_rental_rate_change(p_rental_id uuid,p_effective_at timestamptz,p_daily_rate numeric,p_reason text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r rentals%rowtype; p record; a jsonb; periods jsonb:='[]'; fraction numeric; units numeric; change numeric; tax_change numeric; delta numeric:=0; tax_delta numeric:=0; req jsonb;
begin
 if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
 select * into strict r from rentals where id=p_rental_id;
 if r.status not in ('active','rented','overdue') or r.inspection_completed_at is not null then raise exception 'Only a rental awaiting return can have a dated price change.'; end if;
 if p_daily_rate is null or p_daily_rate<0 or p_daily_rate>100000 or p_daily_rate<>round(p_daily_rate,2) then raise exception 'Enter a daily rate with at most two decimal places.'; end if;
 if length(trim(coalesce(p_reason,'')))<10 or length(p_reason)>1000 then raise exception 'Record the reason and customer agreement (10–1000 characters).'; end if;
 if p_effective_at is null or p_effective_at<(public.rentmect_rental_timestamp(r.pickup_date,r.pickup_time) at time zone 'America/New_York')
 or p_effective_at>=(public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York') then raise exception 'Choose a start within the booked rental dates. Extend the rental first to price additional dates.'; end if;
 if exists(select 1 from rental_extension_requests where rental_id=r.id and status in ('pending','approved_pending_payment')) then raise exception 'Resolve the open extension request before changing the agreed price.'; end if;
 if exists(select 1 from external_payment_receipts where rental_id=r.id and status='pending')
 or exists(select 1 from rental_charge_items where rental_id=r.id and status in ('pending','checkout_open','failed') and (stripe_checkout_session_id is not null or stripe_payment_intent_id is not null))
 or (r.paid_at is null and (r.stripe_checkout_session_id is not null or r.stripe_payment_intent_id is not null)) then
 raise exception 'Finish or cancel the unfinished payment using Manage Payment, then review the price change again.'; end if;
 for p in select * from jsonb_populate_recordset(null::public.rental_pricing_periods,public.rentmect_pricing_snapshot(r.id)) order by starts_at loop
  if p.ends_at>p_effective_at then
   fraction:=public.rentmect_pricing_fraction(p.starts_at,p.ends_at,greatest(p.starts_at,p_effective_at));
   units:=p.billing_units*(1-fraction);
   change:=round((p_daily_rate-p.daily_rate)*units*(1+p.markup_percentage/100),2);
   tax_change:=round(change*0.0635,2);
   if p.rental_amount-round(p.rental_amount*fraction,2)+change<0 or p.tax_amount-round(p.tax_amount*fraction,2)+tax_change<0 then raise exception 'This price is below the remaining discounted amount. Review the existing discount first.'; end if;
   delta:=delta+change; tax_delta:=tax_delta+tax_change;
   periods:=periods||jsonb_build_array(jsonb_build_object('from',greatest(p.starts_at,p_effective_at),'until',p.ends_at,'old_rate',p.daily_rate,'new_rate',p_daily_rate,'billing_units',units,'rental_delta',change,'tax_delta',tax_change));
  end if;
 end loop;
 if not exists(select 1 from jsonb_array_elements(periods) item where (item->>'old_rate')::numeric<>p_daily_rate) then raise exception 'Enter a different daily rate.'; end if;
 a:=public.get_rental_account(r.id);
 req:=jsonb_build_object('rental_id',r.id,'effective_at',p_effective_at,'daily_rate',p_daily_rate,'reason',trim(p_reason));
 return jsonb_build_object('revision',md5(jsonb_build_object('rental',to_jsonb(r),'periods',public.rentmect_pricing_snapshot(r.id),'account',a,'request',req)::text),
 'pricing_before',public.rentmect_pricing_snapshot(r.id),'effective_at',p_effective_at,'ends_at',public.rentmect_rental_timestamp(r.return_date,r.return_time) at time zone 'America/New_York','periods',periods,
 'rental_delta',delta,'tax_delta',tax_delta,'total_delta',delta+tax_delta,'invoice_before',a->'invoice_total','invoice_after',(a->>'invoice_total')::numeric+delta+tax_delta,
 'previous_balance',a->'total_balance_due','balance_due',greatest(0,(a->>'invoice_total')::numeric+delta+tax_delta-(a->>'net_paid')::numeric)+(a->>'additional_balance_due')::numeric,
 'credit_due',greatest(0,(a->>'net_paid')::numeric-(a->>'invoice_total')::numeric-delta-tax_delta),'deposit_held',a->'deposit_held');
end $$;

create function public.admin_apply_rental_rate_change(p_rental_id uuid,p_effective_at timestamptz,p_daily_rate numeric,p_reason text,p_idempotency_key uuid,p_expected_revision text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare q jsonb; req jsonb; prior rental_rate_changes%rowtype; p record; fraction numeric; change numeric; settlement jsonb;
begin
 if auth.uid() is null or not coalesce(public.rentmect_has_permission('rental.edit'),false) then raise exception 'Rental editing permission is required.'; end if;
 if p_idempotency_key is null then raise exception 'A request identifier is required.'; end if;
 perform 1 from rentals where id=p_rental_id for update;
 req:=jsonb_build_object('rental_id',p_rental_id,'effective_at',p_effective_at,'daily_rate',p_daily_rate,'reason',trim(p_reason));
 select * into prior from rental_rate_changes where id=p_idempotency_key;
 if found then
  if prior.request is distinct from req then raise exception 'This request identifier belongs to another price change.'; end if;
  return prior.financial_effect||jsonb_build_object('idempotent_replay',true);
 end if;
 q:=public.admin_preview_rental_rate_change(p_rental_id,p_effective_at,p_daily_rate,p_reason);
 if p_expected_revision is distinct from q->>'revision' then raise exception 'Rental or payments changed. Review the price change again.'; end if;
 perform public.rentmect_initialize_pricing_periods(p_rental_id);
 insert into rental_rate_changes(id,rental_id,actor_id,effective_at,daily_rate,reason,request,financial_effect)
 values(p_idempotency_key,p_rental_id,auth.uid(),p_effective_at,p_daily_rate,trim(p_reason),req,q);
 for p in select * from rental_pricing_periods where rental_id=p_rental_id and ends_at>p_effective_at order by starts_at for update loop
  fraction:=public.rentmect_pricing_fraction(p.starts_at,p.ends_at,greatest(p.starts_at,p_effective_at));
  change:=round((p_daily_rate-p.daily_rate)*p.billing_units*(1-fraction)*(1+p.markup_percentage/100),2);
  if fraction>0 then
   update rental_pricing_periods set ends_at=p_effective_at,billing_units=p.billing_units*fraction,rental_amount=round(p.rental_amount*fraction,2),tax_amount=round(p.tax_amount*fraction,2) where id=p.id;
   insert into rental_pricing_periods(rental_id,starts_at,ends_at,daily_rate,billing_units,markup_percentage,rental_amount,tax_amount,source)
   values(p_rental_id,p_effective_at,p.ends_at,p_daily_rate,p.billing_units*(1-fraction),p.markup_percentage,
   p.rental_amount-round(p.rental_amount*fraction,2)+change,p.tax_amount-round(p.tax_amount*fraction,2)+round(change*0.0635,2),'rate_change');
  else
   update rental_pricing_periods set daily_rate=p_daily_rate,rental_amount=p.rental_amount+change,tax_amount=p.tax_amount+round(change*0.0635,2),source='rate_change',admin_extension_id=null,extension_request_id=null where id=p.id;
  end if;
 end loop;
 perform set_config('rentmect.rate_change',p_idempotency_key::text,true);
 update rentals set rental_total=(select sum(rental_amount) from rental_pricing_periods where rental_id=p_rental_id),tax_amount=(select sum(tax_amount) from rental_pricing_periods where rental_id=p_rental_id),
 agreement_signed=false,agreement_snapshot=null,agreement_hash=null,agreement_version=null,agreement_signed_at=null,agreement_signature_name=null,agreement_ip=null,agreement_user_agent=null,updated_at=now() where id=p_rental_id;
 perform set_config('rentmect.rate_change','',true);
 settlement:=public.sync_rental_remaining_balance(p_rental_id,auth.uid());
 q:=q||jsonb_build_object('pricing_after',public.rentmect_pricing_snapshot(p_rental_id),'settlement',settlement,'idempotent_replay',false);
 update rental_rate_changes set financial_effect=q where id=p_idempotency_key;
 insert into rental_audit_events(rental_id,user_id,actor_id,event_type,event_payload)
 select id,user_id,auth.uid(),'rental_rate_changed',req||q from rentals where id=p_rental_id;
 return q;
end $$;

-- Permit only the exact, recorded price delta through the existing pricing guard.
do $$ declare d text; begin
 select pg_get_functiondef('public.rentmect_guard_dated_rental()'::regprocedure) into d;
 if position('managed:=' in d)=0 then raise exception 'Review the dated pricing guard before installing rate changes.'; end if;
 d:=replace(d,'managed:=', $patch$
 if exists(select 1 from public.rental_rate_changes c where c.id::text=current_setting('rentmect.rate_change',true) and c.rental_id=old.id and c.actor_id=auth.uid()
  and new.rental_total=old.rental_total+(c.financial_effect->>'rental_delta')::numeric and new.tax_amount=old.tax_amount+(c.financial_effect->>'tax_delta')::numeric)
  and (new.vehicle_id,new.pickup_date,new.pickup_time,new.return_date,new.return_time,new.security_deposit,new.base_rental_total,new.manual_discount_amount,new.discount_amount)
   is not distinct from (old.vehicle_id,old.pickup_date,old.pickup_time,old.return_date,old.return_time,old.security_deposit,old.base_rental_total,old.manual_discount_amount,old.discount_amount)
 then return new; end if;
 managed:=$patch$);
 execute d;
end $$;
revoke all on function public.admin_preview_rental_rate_change(uuid,timestamptz,numeric,text),public.admin_apply_rental_rate_change(uuid,timestamptz,numeric,text,uuid,text) from public,anon;
grant execute on function public.admin_preview_rental_rate_change(uuid,timestamptz,numeric,text),public.admin_apply_rental_rate_change(uuid,timestamptz,numeric,text,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
