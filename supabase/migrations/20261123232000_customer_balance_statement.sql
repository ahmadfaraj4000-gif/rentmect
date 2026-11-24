begin;
create function public.rental_balance_statement(p_rental_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r rentals; c rental_charge_items; recipient text; invoice numeric; paid numeric;
  remaining numeric; due numeric; rows text[]; targets jsonb := '[]';
  tourism numeric; charge_total numeric := 0; balance_charge uuid;
begin
  select * into r from rentals where id=p_rental_id;
  if auth.uid() is null or r.id is null or
     (r.user_id is distinct from auth.uid() and rental_operations_staff_name() is null)
  then raise exception 'Statement unavailable.' using errcode='42501'; end if;
  select trim(email) into recipient from profiles where id=r.user_id;
  invoice := rentmect_rental_invoice_total(r.id);
  paid := rentmect_rental_net_paid_amount(r.id);
  due := greatest(0,invoice-paid);
  tourism := least(coalesce(r.service_fee_total,0),coalesce((to_jsonb(r)->>'tourism_surcharge')::numeric,0));
  rows := array[format('Rental period: %s %s through %s %s ET',r.pickup_date,r.pickup_time,r.return_date,r.return_time),
    format('Rental after discounts: $%s',round(r.rental_total,2)),
    format('Rental service fees: $%s',round(coalesce(r.service_fee_total,0)-tourism,2)),
    format('Connecticut tourism surcharge: $%s',round(tourism,2)),
    format('Rental sales tax: $%s',round(coalesce(r.tax_amount,0),2)),
    format('Security deposit on invoice: $%s',round(coalesce(r.security_deposit,0),2))];
  if coalesce(r.cancellation_credit_amount,0)>0 then
    rows:=array_append(rows,format('Cancellation credit: $%s',r.cancellation_credit_amount)); end if;
  rows:=rows || array[format('Rental invoice: $%s',round(invoice,2)),format('Net payments and credits on invoice: $%s',round(paid,2)),
      format('Remaining rental invoice: $%s',round(due,2))];
  if due>0 then
    select id into balance_charge from rental_charge_items where rental_id=r.id and charge_type='rental_amendment'
    and status in ('pending','failed','checkout_open') and rentmect_charge_remaining_amount(rental_charge_items)=due order by created_at desc limit 1;
    targets:=jsonb_build_array(jsonb_build_object('type',case when balance_charge is null then 'rental' else 'charge' end,
      'id',coalesce(balance_charge,r.id),'label','Rental balance','amount',due));
  end if;
  for c in select * from rental_charge_items where rental_id=r.id and not included_in_initial_payment
    and charge_type not in ('rental_amendment','rental_installment') and status in ('pending','failed','checkout_open','paid','waived')
    order by created_at,id loop
    remaining:=rentmect_charge_remaining_amount(c);
    rows:=array_append(rows,format('%s%s — $%s including $%s tax. %s. Remaining $%s.',c.name,
      case when nullif(c.description,'') is null then '' else ' ('||c.description||')' end,c.total_amount,coalesce(c.tax_amount,0),
      case when c.allocated_deposit_cents>0 then format('Deposit applied $%s',round(c.allocated_deposit_cents/100.0,2))
      else initcap(replace(c.status,'_',' ')) end,round(remaining,2)));
    if remaining>0 then
      charge_total:=charge_total+remaining;
      targets:=targets||jsonb_build_array(jsonb_build_object('type','charge','id',c.id,'label',c.name,'amount',remaining));
    end if;
  end loop;
  due:=round(due+charge_total,2);
  rows:=array_append(rows,case when due=0 then 'Paid in full' else format('Total still owed: $%s',due) end);
  return jsonb_build_object('recipient',recipient,'statement',array_to_string(rows,E'\n'),'due',due,'targets',targets);
end $$;
revoke all on function public.rental_balance_statement(uuid) from public,anon;
grant execute on function public.rental_balance_statement(uuid) to authenticated;

insert into public.email_templates(template_key,name,category,subject,html_body,text_body)
values ('renter_balance_statement','Itemized rental balance','automated','Your Rent Me CT rental balance',
 '<h1>Your rental balance</h1><pre style="white-space:pre-wrap;font-family:inherit">{{statement}}</pre><p><a href="{{manage_booking_url}}">Review your current balance and pay</a></p>',
 E'{{statement}}\n\nReview your current balance and pay: {{manage_booking_url}}');

create function public.email_rental_balance_statement(p_rental_id uuid,p_request_id uuid,p_preview jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare s jsonb; request_key text; existing uuid; template uuid;
begin
  if rental_operations_staff_name() is null then raise exception 'Rental operations access required.' using errcode='42501'; end if;
  if p_request_id is null then raise exception 'Request ID required.'; end if;
  perform 1 from rentals where id=p_rental_id for update;
  request_key:='renter_balance:'||p_rental_id||':'||p_request_id;
  select id into existing from email_outbox where event_key=request_key;
  if found then return existing; end if;
  s:=rental_balance_statement(p_rental_id);
  if s is distinct from p_preview then raise exception 'The statement changed. Refresh the preview before sending.'; end if;
  if (s->>'due')::numeric<=0 or nullif(s->>'recipient','') is null then raise exception 'A balance and customer email are required.'; end if;
  select id into strict template from email_templates where template_key='renter_balance_statement' and enabled;
  insert into email_outbox(event_key,email_type,template_id,rental_id,user_id,recipient_email,payload)
  select request_key,'renter_balance_statement',template,r.id,r.user_id,s->>'recipient',
    jsonb_build_object('statement',s->>'statement','manage_booking_url','https://login.rentmect.com/?billing=1&statement='||r.id)
    from rentals r where r.id=p_rental_id returning id into existing;
  return existing;
end $$;
revoke all on function public.email_rental_balance_statement(uuid,uuid,jsonb) from public,anon;
grant execute on function public.email_rental_balance_statement(uuid,uuid,jsonb) to authenticated;
commit;
