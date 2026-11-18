-- Admin decision (18 Nov 2026): no automatic pairing in Company vs AEO vs Head Teacher.
-- Mismatched invoices stay open until an admin settles them manually (Settle issues checklist).
-- Already applied live; recorded here so the repo matches the database.

-- 1) Company vs AEO "nearest date" pairing off (rules stay in the table, inactive).
update public.company_aeo_date_pairing_rules set active = false;

-- 2) Head-teacher fuzzy pairing (same school/product/quantity + close number or date) off.
--    Only manual 'pair_head' settlements and identical challan numbers pair now.
do $$
declare d text;
begin
  d := pg_get_viewdef('public.v_three_way_base'::regclass, true);
  if position('WHERE rk.rb = 1 AND rk.rp = 1 AND false' in d) = 0 then
    if position('WHERE rk.rb = 1 AND rk.rp = 1' in d) = 0 then raise exception 'marker not found'; end if;
    d := replace(d, 'WHERE rk.rb = 1 AND rk.rp = 1', 'WHERE rk.rb = 1 AND rk.rp = 1 AND false');
    execute 'create or replace view public.v_three_way_base as ' || rtrim(d, E'; \n');
  end if;
end $$;
