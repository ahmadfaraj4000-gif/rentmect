begin;
set local lock_timeout='5s';
-- Once provider attempts have been retired, the receipt must clear their start marker.
do $$ declare definition text; marker text; begin
 select pg_get_functiondef('public.service_finish_external_payment(uuid,uuid,boolean)'::regprocedure) into definition;
 marker:='stripe_checkout_session_id=null,stripe_payment_intent_id=null,last_admin_charge_error=null';
 if position(marker in definition)=0 then raise exception 'Review changed receipt posting.'; end if;
 execute replace(definition,marker,'stripe_checkout_session_id=null,stripe_payment_intent_id=null,admin_charge_attempted_at=null,last_admin_charge_error=null');
 select pg_get_functiondef('public.protect_deposit_settlement()'::regprocedure) into definition;
 execute replace(definition,'''paid_at'',''updated_at'',''last_admin_charge_error''','''paid_at'',''updated_at'',''admin_charge_attempted_at'',''last_admin_charge_error''');
end $$;
notify pgrst,'reload schema';
commit;
