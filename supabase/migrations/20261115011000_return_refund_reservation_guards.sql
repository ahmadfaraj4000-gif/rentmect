begin;
set local lock_timeout='5s';
-- An old tab must not reserve a second refund while the return workspace owns credit.
create function public.guard_return_refund_reservation() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.source_type='admin_rental_payment' and new.stripe_refund_id is null and new.status in ('processing','pending') then
  perform 1 from rentals where id=new.rental_id for update;
  if exists(select 1 from rental_return_credit_sources where rental_id=new.rental_id) then
   raise exception 'Use the saved deposit and credit return; this account already has reserved or returned credit.';
  end if;
 end if;
 return new;
end $$;
create trigger protect_return_refund_reservation before insert on public.rental_payment_refunds for each row execute function public.guard_return_refund_reservation();
do $$ declare d text; begin
 select pg_get_functiondef('public.service_apply_deposit_review(uuid,uuid,uuid,jsonb,jsonb,jsonb)'::regprocedure) into d;
 if position('if r.status<>''completed''' in d)=0 then raise exception 'Review return settlement contract.'; end if;
 d:=replace(d,'if r.status<>''completed''',$guard$
 if exists(select 1 from rental_payment_refunds where rental_id=r.id and status in ('processing','pending')) then
  raise exception 'A previous refund is still processing. Reconcile it before creating a return settlement.';
 end if;
 if r.status<>'completed'$guard$);
 execute d;
end $$;
notify pgrst,'reload schema';
commit;
