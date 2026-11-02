-- WhatsApp data collection: the "not accepted" reply now names the SPECIFIC mistake instead of repeating the whole format.
--   wrong EMIS code     -> "32220660 - EMIS code is wrong"
--   other school's code -> "32220545 - this school is not in your markaz" (etc.)
--   date / product left out -> the single missing line to add
--   completely unreadable message -> (only this one) the full format to copy
-- Run after 20261108. Safe to run more than once.
do $$
declare d text; n text;
begin
  d := pg_get_functiondef('public.fn_wa_collect_ingest(text,text,text,text,text)'::regprocedure);
  if position('is wrong' in d) > 0 and position('Please correct and send it again.' in d) > 0 then return; end if;
  d := replace(d, E'\r\n', E'\n');
  n := d;
  n := replace(n, 'v_err := ''EMIS code not found'';', 'v_err := ''EMIS code is wrong'';');
  n := replace(n, 'v_err := ''school is not in your markaz'';', 'v_err := ''this school is not in your markaz'';');
  n := replace(n, 'v_err := ''school is not in this group''''s jurisdiction'';', 'v_err := ''this school is not in this group''''s area'';');
  n := replace(n, 'return E''⚠ Not accepted - format not followed by cell 0'' || v_phone || '' - EMIS code(s):'' || v_lines || v_footer;',
$r$return E'⚠ Not accepted - cell 0' || v_phone || ':' || v_lines
    || case when v_lines like '%date missing%' or v_lines like '%product missing%'
            then E'\nAdd to the same message:\nDate: ' || coalesce(v_fd, to_char(v_today, 'FMDay, DD Mon YYYY')) || coalesce(E'\nProduct: ' || v_fp, '') else '' end
    || E'\nPlease correct it and send again.';$r$);
  if n = d or position('is wrong' in n) = 0 or position('Add to the same message' in n) = 0 then
    raise exception 'ingest text not as expected - reply patch not applied';
  end if;
  n := replace(n, 'Please correct it and send again.', 'Please correct and send it again.');   -- the marker used by the "already applied" check above
  execute n;
end $$;
