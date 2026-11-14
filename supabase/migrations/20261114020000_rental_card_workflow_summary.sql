begin;
set local lock_timeout='150ms';
set local statement_timeout='5s';
-- Header/workflow metadata only. No files, receipt history, ledger, or audit rows.
create function public.admin_rental_card_summary(p_rental_id uuid) returns jsonb
language plpgsql stable security invoker set search_path=public as $$
declare result jsonb;
begin
 if auth.uid() is null or not public.is_admin() or not coalesce(public.rentmect_has_permission('tab.rentals'),false) then
  raise exception 'Rental access is required.' using errcode='42501'; end if;
 select jsonb_build_object(
  'rental',jsonb_build_object('agreement_signed',r.agreement_signed,'merchant_id',r.merchant_id,
   'booking_source',r.booking_source,'merchant_reservation_number',r.merchant_reservation_number,
   'merchant_identity_verified',case when r.merchant_id is not null then coalesce((public.get_customer_merchant_verification(r.id)->>'verified')::boolean,false) else false end,
   'starting_mileage',r.starting_mileage,'inspection_completed_at',r.inspection_completed_at,
   'deposit_held_amount',r.deposit_held_amount,'deposit_released_amount',r.deposit_released_amount,
   'deposit_review_approved_at',r.deposit_review_approved_at,'deposit_release_error',r.deposit_release_error,
   'cancelled_before_pickup_at',r.cancelled_before_pickup_at,'customer_auth_deleted_at',r.customer_auth_deleted_at,
   'profiles',jsonb_build_object('phone_verified',p.phone_verified,'phone_verified_at',p.phone_verified_at,
    'identity_verification_status',p.identity_verification_status,'identity_verification_method',p.identity_verification_method)),
  'documents',coalesce((select jsonb_agg(to_jsonb(d)) from (
    (select id,user_id,rental_id,document_type,status,created_at,updated_at,insurance_packet_id,insurance_coverage_type,extension_request_id
     from rental_documents where document_type='license' and (rental_id=r.id or user_id=r.user_id)
     order by coalesce(updated_at,created_at) desc,id desc limit 1)
    union all
    (select id,user_id,rental_id,document_type,status,created_at,updated_at,insurance_packet_id,insurance_coverage_type,extension_request_id
     from rental_documents where rental_id=r.id and document_type='insurance' and extension_request_id is null
     and coalesce(insurance_packet_id,id)=(select coalesce(x.insurance_packet_id,x.id) from rental_documents x
       where x.rental_id=r.id and x.document_type='insurance' and x.extension_request_id is null order by x.created_at desc,x.id desc limit 1))
   ) d),'[]'::jsonb),
  'completion_scopes',coalesce((select jsonb_agg(step_key) from rental_step_completions where rental_id=r.id),'[]'::jsonb),
  'emergency',(select jsonb_build_object('status',e.status,'expires_at',e.expires_at,'exception_scopes',e.exception_scopes,'resolved_scopes',e.resolved_scopes)
   from rental_emergency_exceptions e where e.rental_id=r.id and e.status='active' and e.expires_at>now() limit 1),
  'extensions',coalesce((select jsonb_agg(to_jsonb(e)) from (select id,rental_id,status,updated_at,created_at,extension_total_amount,requested_return_date,requested_return_time
   from rental_extension_requests where rental_id=r.id and status in ('pending','approved_pending_payment') order by updated_at desc limit 1) e),'[]'::jsonb),
  'returned_card_amount',(select coalesce(sum(amount),0) from rental_payment_refunds where rental_id=r.id and extension_request_id is null and status='succeeded')
 ) into result from rentals r left join profiles p on p.id=r.user_id where r.id=p_rental_id;
 return result;
end $$;
revoke all on function public.admin_rental_card_summary(uuid) from public,anon;
grant execute on function public.admin_rental_card_summary(uuid) to authenticated;
-- Add the header projection after pagination, including in Realtime deltas.
do $$ declare signature text; d text; needle text:='to_jsonb(page)-array[''search_text'',''matches'']'; begin
 foreach signature in array array['public.admin_rental_list(text,text,integer,integer,uuid)',
 'public.admin_rental_summary_changes(text,text,integer,integer,uuid,uuid[],uuid[])'] loop
  select pg_get_functiondef(signature::regprocedure) into d;
  if position(needle in d)=0 or position('admin_rental_card_summary' in d)>0 then raise exception 'Rental summary baseline changed: %',signature; end if;
  d:=replace(d,needle,'('||needle||')||jsonb_build_object(''card'',public.admin_rental_card_summary(page.id))');
  execute d;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
