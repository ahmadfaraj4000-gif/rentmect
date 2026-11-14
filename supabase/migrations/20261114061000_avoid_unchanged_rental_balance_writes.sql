-- Keep all settlement and authorization behavior; avoid unchanged row versions.
begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
do $guard$ begin
 if (select md5(prosrc) from pg_proc where oid='public.sync_rental_remaining_balance(uuid,uuid)'::regprocedure)
 <> '4f5b73902cb875da32f4f77a95583504' then
 raise exception 'Review changed production balance reconciliation before applying'; end if;
end $guard$;
CREATE OR REPLACE FUNCTION public.sync_rental_remaining_balance(p_rental_id uuid, p_actor_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_rental public.rentals%rowtype;
  v_balance_charge public.rental_charge_items%rowtype;
  v_invoice numeric;
  v_paid numeric;
  v_due numeric;
  v_credit numeric;
  v_next_status text;
  v_final_provider text;
begin
  select * into v_rental
  from public.rentals
  where id = p_rental_id
  for update;
  if not found then raise exception 'Rental not found.'; end if;

  v_invoice := public.rentmect_rental_invoice_total(v_rental.id);
  v_paid := public.rentmect_rental_net_paid_amount(v_rental.id);
  v_due := greatest(0, round(v_invoice - v_paid, 2));
  v_credit := greatest(0, round(v_paid - v_invoice, 2));

  select * into v_balance_charge
  from public.rental_charge_items
  where rental_id = v_rental.id
    and charge_type = 'rental_amendment'
    and status in ('pending', 'checkout_open', 'failed')
  order by created_at desc, id desc
  limit 1
  for update;

  update public.rental_charge_items
  set status = 'waived',
      description = 'Superseded by the current remaining rental balance.',
      updated_at = now()
  where rental_id = v_rental.id
    and charge_type = 'rental_amendment'
    and status in ('pending', 'checkout_open', 'failed')
    and (v_balance_charge.id is null or id <> v_balance_charge.id);

  if v_due > 0.005 then
    if v_balance_charge.id is null then
      insert into public.rental_charge_items (
        rental_id, user_id, name, charge_type, description,
        amount, taxable, tax_amount, total_amount,
        included_in_initial_payment, status, created_by,
        source_type, source_reference
      ) values (
        v_rental.id, v_rental.user_id, 'Remaining rental balance',
        'rental_amendment',
        'Unpaid portion of the rental invoice after crediting payments already received.',
        v_due, false, 0, v_due, false, 'pending', p_actor_id,
        'rental_balance', gen_random_uuid()::text
      ) returning * into v_balance_charge;
    else
      if row(v_balance_charge.name,v_balance_charge.description,v_balance_charge.amount,
        v_balance_charge.taxable,v_balance_charge.tax_amount,v_balance_charge.total_amount,
        v_balance_charge.status,v_balance_charge.payment_amount_cents,v_balance_charge.last_admin_charge_error)
      is distinct from row('Remaining rental balance'::text,
        'Unpaid portion of the rental invoice after crediting payments already received.'::text,
        v_due,false,0::numeric,v_due,
        case when v_balance_charge.status='checkout_open' then 'checkout_open' else 'pending' end,
        round(v_due*100)::integer,null::text) then
      update public.rental_charge_items
      set name = 'Remaining rental balance',
          description = 'Unpaid portion of the rental invoice after crediting payments already received.',
          amount = v_due,
          taxable = false,
          tax_amount = 0,
          total_amount = v_due,
          status = case when status = 'checkout_open' then 'checkout_open' else 'pending' end,
          payment_amount_cents = round(v_due * 100)::integer,
          last_admin_charge_error = null,
          updated_at = now()
      where id = v_balance_charge.id
      returning * into v_balance_charge;
      end if;
    end if;
    v_next_status := case when v_paid > 0.005 then 'partially_paid' else 'pending' end;
  else
    if v_balance_charge.id is not null then
      update public.rental_charge_items
      set status = 'waived',
          description = 'No remaining rental balance after invoice reconciliation.',
          updated_at = now()
      where id = v_balance_charge.id;
      v_balance_charge.id := null;
    end if;
    v_next_status := case when v_paid > 0.005 then 'paid' else 'pending' end;
  end if;

  if v_next_status = 'paid' then
    select charge.payment_provider into v_final_provider
    from public.rental_charge_items charge
    where charge.rental_id = v_rental.id
      and charge.charge_type = 'rental_amendment'
      and charge.status = 'paid'
      and charge.payment_provider is not null
    order by charge.paid_at desc nulls last, charge.created_at desc
    limit 1;
    -- payment_provider may merely describe an abandoned Stripe quote. Trust it
    -- only when the rental-level payment was actually captured.
    v_final_provider := coalesce(
      case when v_rental.paid_at is not null
        then nullif(v_rental.payment_provider, '') end,
      v_final_provider,
      'local'
    );
  end if;

  update public.rentals
  set payment_status = v_next_status,
      payment_provider = case
        when v_next_status = 'paid' then v_final_provider
        else payment_provider
      end,
      deposit_status = case
        when v_next_status = 'paid' and coalesce(security_deposit, 0) <= 0 then 'waived'
        when v_next_status = 'paid'
          and lower(coalesce(deposit_status, 'pending')) in ('pending', 'not_due') then 'held'
        else deposit_status
      end,
      deposit_held_amount = case
        when exists(select 1 from public.rental_deposit_allocations where holder_rental_id=v_rental.id)
          then (select coalesce(sum(greatest(0,amount_held-amount_applied-amount_released)),0)
            from public.rental_deposit_allocations where holder_rental_id=v_rental.id)
        when v_next_status = 'paid' then greatest(
          coalesce(deposit_held_amount, 0), coalesce(security_deposit, 0)
        )
        else deposit_held_amount
      end,
      checkout_expires_at = case
        when v_next_status in ('paid', 'partially_paid') then null
        else checkout_expires_at
      end,
      payment_due_at = case
        when v_next_status in ('paid', 'partially_paid') then null
        else payment_due_at
      end,
      updated_at = now()
  where id = v_rental.id
    and row(payment_status, payment_provider, deposit_status, deposit_held_amount, checkout_expires_at, payment_due_at)
      is distinct from row((v_next_status),
        (case
        when v_next_status = 'paid' then v_final_provider
        else payment_provider
      end),
        (case
        when v_next_status = 'paid' and coalesce(security_deposit, 0) <= 0 then 'waived'
        when v_next_status = 'paid'
          and lower(coalesce(deposit_status, 'pending')) in ('pending', 'not_due') then 'held'
        else deposit_status
      end),
        (case
        when exists(select 1 from public.rental_deposit_allocations where holder_rental_id=v_rental.id)
          then (select coalesce(sum(greatest(0,amount_held-amount_applied-amount_released)),0)
            from public.rental_deposit_allocations where holder_rental_id=v_rental.id)
        when v_next_status = 'paid' then greatest(
          coalesce(deposit_held_amount, 0), coalesce(security_deposit, 0)
        )
        else deposit_held_amount
      end),
        (case
        when v_next_status in ('paid', 'partially_paid') then null
        else checkout_expires_at
      end),
        (case
        when v_next_status in ('paid', 'partially_paid') then null
        else payment_due_at
      end));

  if v_paid > 0.005
     and lower(coalesce(v_rental.status, 'pending')) in (
       'pending', 'documents_needed', 'document_review', 'approved', 'ready_for_pickup'
     ) then
    update public.vehicles
    set status = 'reserved'
    where id = v_rental.vehicle_id
      and lower(coalesce(status, 'available')) = 'available';
  end if;

  if v_next_status = 'paid' then
    if not exists(select 1 from public.rental_deposit_charge_applications where rental_id=v_rental.id) then
      perform public.ensure_rental_deposit_allocation(v_rental.id);
    end if;

    insert into public.rental_step_completions (
      rental_id, user_id, step_key, completion_source,
      note, metadata, completed_by
    ) values (
      v_rental.id, v_rental.user_id, 'payment',
      case when v_final_provider = 'stripe'
        then 'stripe_payment' else 'admin_external_payment' end,
      'Rental balance paid in full.',
      jsonb_build_object('net_paid', v_paid, 'payment_provider', v_final_provider),
      p_actor_id
    )
    on conflict (rental_id, step_key) do update set
      completion_source = excluded.completion_source,
      note = excluded.note,
      metadata = excluded.metadata,
      completed_by = excluded.completed_by,
      completed_at = now(),
      updated_at = now()
    where row(rental_step_completions.completion_source,rental_step_completions.note,
      rental_step_completions.metadata,rental_step_completions.completed_by)
      is distinct from row(excluded.completion_source,excluded.note,excluded.metadata,excluded.completed_by);

    insert into public.rental_step_completions (
      rental_id, user_id, step_key, completion_source,
      note, metadata, completed_by
    ) values (
      v_rental.id, v_rental.user_id, 'deposit',
      case when coalesce(v_rental.security_deposit, 0) > 0
        then 'admin_deposit_collected' else 'admin_deposit_waived' end,
      case when coalesce(v_rental.security_deposit, 0) > 0
        then 'Deposit completed with the final rental balance payment.'
        else 'No security deposit was due.' end,
      jsonb_build_object('amount', coalesce(v_rental.security_deposit, 0)),
      p_actor_id
    )
    on conflict (rental_id, step_key) do update set
      completion_source = excluded.completion_source,
      note = excluded.note,
      metadata = excluded.metadata,
      completed_by = excluded.completed_by,
      completed_at = now(),
      updated_at = now()
    where row(rental_step_completions.completion_source,rental_step_completions.note,
      rental_step_completions.metadata,rental_step_completions.completed_by)
      is distinct from row(excluded.completion_source,excluded.note,excluded.metadata,excluded.completed_by);
  end if;

  return jsonb_build_object(
    'rental_id', v_rental.id,
    'invoice_total', v_invoice,
    'net_paid', v_paid,
    'balance_due', v_due,
    'credit_due', v_credit,
    'payment_status', v_next_status,
    'balance_charge_id', v_balance_charge.id
  );
end;
$$;
commit;
