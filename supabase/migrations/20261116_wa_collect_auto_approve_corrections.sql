-- Auto-approve now also covers corrections (a different figure for a day that is already recorded):
-- after the admin's auto-approve time they update the recorded figure automatically, like new entries.
do $$
declare d text;
begin
  select replace(pg_get_functiondef(p.oid), E'\r', '') into d
    from pg_proc p where p.proname = 'fn_wa_collect_auto_approve' and p.pronamespace = 'public'::regnamespace;
  if position('status = ''pending'' and kind = ''new'' and' in d) = 0 then
    if position('status = ''pending'' and consumption_date' in d) > 0 then return; end if;   -- already patched
    raise exception 'auto-approve text not as expected - not patched';
  end if;
  d := replace(d, 'status = ''pending'' and kind = ''new'' and', 'status = ''pending'' and');
  execute d;
end $$;
