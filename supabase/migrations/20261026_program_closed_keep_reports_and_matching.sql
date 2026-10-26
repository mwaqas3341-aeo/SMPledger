-- While the program is closed: reports keep working (read-only), missing-consumption reports cover the closed period,
-- and an Admin can still make invoice-matching corrections on school receipts.
-- Quantity, product, status and all inserts/deletes stay blocked for everyone. Already applied to the live project.
do $$
declare d text; n int;
begin
  d := pg_get_functiondef('public.fn_program_guard()'::regprocedure);
  n := (length(d) - length(replace(d, E'  if not st.is_open then\n', ''))) / length(E'  if not st.is_open then\n');
  if n <> 1 then raise exception 'unexpected guard definition (% matches)', n; end if;
  d := replace(d, E'  if not st.is_open then\n', E'  if not st.is_open then\n' ||
    E'    if tg_table_name = ''school_receipts'' and tg_op = ''UPDATE'' and public.fn_is_admin() then\n' ||
    E'      jo := to_jsonb(old) - ign - array[''receipt_date'',''invoice_number'',''invoice_id'',''school_id'',''original_receipt_date'',''original_invoice_number'',''original_school_id'',''reconciled_at'',''reconciled_note'',''verified'',''remarks''];\n' ||
    E'      jn := to_jsonb(new) - ign - array[''receipt_date'',''invoice_number'',''invoice_id'',''school_id'',''original_receipt_date'',''original_invoice_number'',''original_school_id'',''reconciled_at'',''reconciled_note'',''verified'',''remarks''];\n' ||
    E'      if jo = jn then return new; end if;\n' ||
    E'    end if;\n');
  execute d;
end $$;

create or replace function public.fn_missing_consumption_period(p_school_ids uuid[], p_from date, p_to date)
returns table(school_id uuid, emis_code text, school_name text, markaz_name text, tehsil text, wing text, product_id uuid, product_name text, missing_date date)
language sql stable as $$
  select c.* from public.program_state st,
    lateral public.fn_missing_consumption_period_core(
      p_school_ids,
      greatest(p_from, st.start_date),
      case when st.is_open then p_to else least(p_to, (select max(end_date) from public.program_periods)) end) c;
$$;
