begin;
-- A rejected inspection must not leave a damage case, customer notice or flag.
alter function public.admin_inspect_and_complete_rental_return(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean)
 rename to admin_inspect_and_complete_rental_return_core;
revoke all on function public.admin_inspect_and_complete_rental_return_core(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean) from public,anon,authenticated;
create function public.admin_inspect_and_complete_rental_return(
 p_rental_id uuid,p_ending_mileage integer,p_mileage_checked boolean,p_fuel_checked boolean,
 p_damage_checked boolean,p_damage_found boolean,p_deposit_decision text,p_notes text default null,
 p_vehicle_disposition text default 'available',p_mileage_override boolean default false,
 p_return_context jsonb default null)
returns public.rentals language plpgsql security definer set search_path=public as $$
declare r rentals%rowtype; paths text[]:='{}'; path text; issue text; customer_action text;
 report_needed boolean; message_text text;
begin
 if auth.uid() is null or not coalesce(rentmect_has_permission('rental.return'),false) then
  raise exception 'Rental return permission is required.'; end if;
 if p_return_context is not null and jsonb_typeof(p_return_context)<>'object' then
  raise exception 'Return details must be an object.'; end if;
 if p_return_context ? 'photo_paths' then
  if jsonb_typeof(p_return_context->'photo_paths')<>'array' then raise exception 'Return evidence must be a list.'; end if;
  select coalesce(array_agg(value),'{}') into paths from jsonb_array_elements_text(p_return_context->'photo_paths');
 end if;
 select * into strict r from rentals where id=p_rental_id for update;
 foreach path in array paths loop
  if path is null or path not like r.user_id::text||'/return-damage/'||r.id::text||'/%' or path like '%..%' then
   raise exception 'Return evidence must belong to this customer and rental.'; end if;
 end loop;
 issue:=coalesce(nullif(trim(p_return_context->>'issue_type'),''),'damage');
 customer_action:=case when p_damage_found then coalesce(p_return_context->>'customer_action','none') else 'none' end;
 if customer_action not in ('none','review','block') then raise exception 'Choose a valid customer action.'; end if;
 report_needed:=p_return_context is not null and (p_damage_found or (p_deposit_decision='hold' and cardinality(paths)>0));
 -- These changes, and the core inspection, commit in the same database transaction.
 r:=admin_inspect_and_complete_rental_return_core(p_rental_id,p_ending_mileage,p_mileage_checked,
   p_fuel_checked,p_damage_checked,p_damage_found,p_deposit_decision,p_notes,p_vehicle_disposition,p_mileage_override);
 if report_needed then
  insert into vehicle_reports(rental_id,user_id,vehicle_id,status,description,report_type,issue_type,photo_paths,deposit_held_amount,admin_notes)
  values(r.id,r.user_id,r.vehicle_id,'open',coalesce(nullif(p_notes,''),'Damage found during admin return inspection.'),
   'admin_return_damage',case when p_damage_found then issue else 'other' end,to_jsonb(paths),coalesce(r.security_deposit,0),coalesce(p_notes,''));
  message_text:='RETURN REVIEW OPENED: Rent Me CT opened a '||case when p_damage_found then replace(issue,'_',' ') else 'deposit' end||
   ' review for your returned rental. Your security deposit is being held while the review is completed. '||
   case when nullif(p_notes,'') is not null then 'Admin note: '||p_notes else 'We will update you when the case is resolved.' end;
  insert into rental_messages(rental_id,user_id,sender_role,message,read_by_admin)
  values(r.id,r.user_id,'admin',message_text,true);
 end if;
 if customer_action<>'none' then
  perform admin_set_customer_status(r.user_id,case when customer_action='block' then 'blocked' else 'review_required' end,
   coalesce(nullif(p_notes,''),'Damage case opened from return inspection.'));
 end if;
 return r;
end $$;
revoke all on function public.admin_inspect_and_complete_rental_return(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean,jsonb) from public,anon;
grant execute on function public.admin_inspect_and_complete_rental_return(uuid,integer,boolean,boolean,boolean,boolean,text,text,text,boolean,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
