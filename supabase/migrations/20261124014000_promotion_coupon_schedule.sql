-- Codes created for a campaign follow the published advertising window exactly.
alter table public.discount_codes add column if not exists promotion_only boolean not null default false;

do $migration$
declare
  original text := pg_get_functiondef('public.apply_customer_discount_to_rental(uuid,text)'::regprocedure);
  marker text := 'if v_code.starts_at is not null';
  guard text := $guard$if v_code.promotion_only and not exists (
    select 1 from public.site_promotions p where p.discount_code_id = v_code.id
    and p.active and (p.starts_at is null or p.starts_at <= now()) and p.ends_at > now()
  ) then raise exception 'This discount is available only during its published promotion.'; end if;
  $guard$;
begin
  if strpos(original,guard) > 0 then return; end if;
  if strpos(original,marker) = 0 then raise exception 'Discount validation point missing'; end if;
  execute replace(original,marker,guard || marker);
end $migration$;
