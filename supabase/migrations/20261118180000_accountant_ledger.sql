begin;

create function public.can_view_accountant_ledger() returns boolean
language sql stable security invoker set search_path = pg_catalog,public as $$
  select coalesce(public.is_admin(), false)
    and exists (select 1 from public.profiles where id=auth.uid() and lower(email)='anconamgt@aol.com')
$$;
revoke all on function public.can_view_accountant_ledger() from public,anon;
grant execute on function public.can_view_accountant_ledger() to authenticated;

-- Preserve the deployed transaction and dashboard definitions, including prior fixes.
do $$
declare
  original text;
  updated text;
begin
  original := pg_get_functiondef('public.admin_payment_activity_page(text,text,integer)'::regprocedure);
  updated := replace(original, 'return result;', $body$return case when public.can_view_accountant_ledger() then result else result - 'totals' end;$body$);
  if updated = original then raise exception 'Unexpected payment activity definition'; end if;
  if position('p_offset<0' in updated)=0 or position('offset p_offset limit 51' in updated)=0
     or position('id desc limit 50)' in updated)=0 then raise exception 'Unexpected payment pagination'; end if;
  updated := replace(updated, 'p_offset<0', '(p_offset<0 and not (p_offset=-1 and public.can_view_accountant_ledger()))');
  updated := replace(updated, 'offset p_offset limit 51', 'offset greatest(0,p_offset) limit (case when p_offset>=0 then 51 end)');
  updated := replace(updated, 'id desc limit 50)', 'id desc limit (case when p_offset>=0 then 50 end))');
  execute updated;
  original := pg_get_functiondef('public.get_admin_dashboard_snapshot()'::regprocedure);
  updated := replace(original, 'return v_snapshot;', $body$return case when public.can_view_accountant_ledger() then v_snapshot else v_snapshot - 'month_revenue' - 'active_deposits' end;$body$);
  if updated = original then raise exception 'Unexpected dashboard definition'; end if;
  execute updated;
end $$;

-- All sections read one statement snapshot. Offset -1 requests full owner activity.
create function public.admin_accountant_ledger() returns jsonb
language plpgsql stable security invoker set search_path = pg_catalog,public as $$
declare
  snapshot jsonb;
  activity jsonb;
begin
  if not public.can_view_accountant_ledger() then
    raise exception 'Owner access required.' using errcode='42501';
  end if;
  snapshot := public.admin_payment_revenue_snapshot();
  activity := public.admin_payment_activity_page('all','all',-1)->'rows';
  return jsonb_build_object('asOf', statement_timestamp(), 'revenue', snapshot, 'transactions',activity,
    'rentals',coalesce((select jsonb_agg(to_jsonb(d) order by pickup_date,id) from (
      select r.id,r.pickup_date,r.return_date,r.status,r.payment_status,
        coalesce(nullif(r.customer_name_snapshot,''),p.full_name) customer,v.name vehicle,
        r.rental_total,r.discount_amount,r.discount_code,r.manual_discount_amount,r.service_fee_total,r.tax_amount,
        (account->>'invoice_total')::numeric invoice_total,(account->>'net_paid')::numeric net_paid,
        (account->>'balance_due')::numeric booking_due,(account->>'credit_due')::numeric credit_due,
        r.under_25_markup_amount,r.security_deposit,r.deposit_status,r.deposit_held_amount,r.deposit_released_amount
      from public.rentals r left join public.vehicles v on v.id=r.vehicle_id left join public.profiles p on p.id=r.user_id
      cross join lateral public.get_rental_account(r.id) account
    ) d),'[]'::jsonb),
    'fees',coalesce((select jsonb_agg(to_jsonb(f) order by created_at,id) from (
      select id,rental_id,name,charge_type,status,created_at,total_amount,tax_amount,payment_provider,
        included_in_initial_payment,allocation_managed,allocated_payment_cents,allocated_deposit_cents,
        allocated_waiver_cents,payment_amount_cents,external_refunded_amount
      from public.rental_charge_items where charge_type not in ('rental_installment','rental_amendment') and flex_payment_receipt_id is null
    ) f),'[]'::jsonb));
end $$;
revoke all on function public.admin_accountant_ledger() from public,anon;
grant execute on function public.admin_accountant_ledger() to authenticated;
notify pgrst,'reload schema';
commit;
