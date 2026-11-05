create role anon; create role authenticated; create role service_role;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.role() returns text language sql as $$select current_setting('request.jwt.claim.role',true)$$;
create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create table profiles(id uuid primary key,role text,staff_role text);
create table staff_permission_overrides(user_id uuid,permission_key text,enabled boolean);
create table employee_permissions(permission_key text,enabled boolean);
create function public.is_admin() returns boolean language sql as $$select exists(select 1 from profiles where id=auth.uid() and role='admin')$$;
create function public.rentmect_has_permission(text) returns boolean language sql as $$select is_admin()$$;
create table rentals(id uuid primary key,user_id uuid);
create table rental_audit_events(id uuid default gen_random_uuid(),rental_id uuid,user_id uuid,actor_id uuid,event_type text,event_payload jsonb);
create table rental_charge_items(
"id" uuid primary key,
"rental_id" uuid,
"user_id" uuid,
"service_fee_id" uuid,
"name" text,
"charge_type" text,
"description" text,
"amount" numeric,
"taxable" boolean,
"tax_amount" numeric,
"total_amount" numeric,
"included_in_initial_payment" boolean not null default false,
"status" text,
"payment_provider" text,
"stripe_checkout_session_id" text,
"stripe_payment_intent_id" text,
"payment_amount_cents" integer,
"payment_currency" text,
"paid_at" timestamp with time zone,
"created_by" uuid,
"created_at" timestamp with time zone,
"updated_at" timestamp with time zone,
"stripe_customer_id" text,
"admin_charge_attempts" integer default 0,
"admin_charge_attempted_at" timestamp with time zone,
"last_admin_charge_error" text,
"source_type" text,
"source_reference" text,
"external_payment_method" text,
"external_payment_reference" text,
"external_payment_recorded_by" uuid);
create table tollspot_transactions(id uuid default gen_random_uuid(),rental_charge_item_id uuid,status text,ignored_reason text,updated_at timestamptz);
CREATE OR REPLACE FUNCTION public.sync_tollspot_transaction_from_charge()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.source_type, '') <> 'tollspot'
     or old.status is not distinct from new.status then
    return new;
  end if;
  if new.status = 'paid' then
    update public.tollspot_transactions
    set status = 'paid', updated_at = now()
    where rental_charge_item_id = new.id;
  elsif new.status = 'waived' then
    update public.tollspot_transactions
    set status = 'ignored',
        ignored_reason = 'Linked customer charge was waived by an administrator.',
        updated_at = now()
    where rental_charge_item_id = new.id;
  end if;
  return new;
end;
$function$
;
CREATE TRIGGER rental_charges_sync_tollspot_status AFTER UPDATE OF status ON public.rental_charge_items FOR EACH ROW EXECUTE FUNCTION sync_tollspot_transaction_from_charge();
