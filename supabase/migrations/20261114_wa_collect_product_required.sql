-- Date, Product and EMIS code (and packs) are all required in a group message.
-- Until now, when the Product line was missing but only one product was distributed that day, the
-- system guessed the product. That guess is removed: a message without a Product line is rejected
-- with "product missing - add the Product line in the same message".
do $$
declare d text;
begin
  select replace(pg_get_functiondef(p.oid), E'\r', '') into d
    from pg_proc p where p.proname = 'fn_wa_collect_ingest' and p.pronamespace = 'public'::regnamespace;
  if d like '%if false then  -- product required%' then return; end if;
  if position('if v_prod is null and v_date is not null then' in d) = 0 then
    raise exception 'ingest text not as expected - product rule not patched';
  end if;
  d := replace(d, 'if v_prod is null and v_date is not null then', 'if false then  -- product required: never guessed');
  execute d;
end $$;
