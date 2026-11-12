begin;
set local lock_timeout='5s';
-- A payment link's creation date is not the date money was received.
-- Stamp the first verified posting; retries return before touching this timestamp.
do $$ declare d text; marker text; begin
 select pg_get_functiondef('public.service_confirm_allocated_stripe(uuid,text,text,integer,text,boolean)'::regprocedure) into d;
 marker:='if not p_cancel then update external_payment_receipts set stripe_payment_intent_id=p_intent where id=p_id; end if;';
 if position(marker in d)=0 then raise exception 'Review Stripe confirmation before changing its receipt timestamp.';end if;
 execute replace(d,marker,$patch$if not p_cancel then update external_payment_receipts set stripe_payment_intent_id=p_intent,
  received_date=(now() at time zone 'America/New_York')::date,
  received_time=(now() at time zone 'America/New_York')::time where id=p_id; end if;$patch$);
end $$;
notify pgrst,'reload schema';
commit;
