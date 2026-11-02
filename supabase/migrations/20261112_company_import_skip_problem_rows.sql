-- Company import: a mismatch inside the company file no longer blocks the upload.
-- Flag mode (p_skip_problems=true, used by the Upload wizard):
--   * every company row is imported, including rows whose invoice number is reused inside the file
--     for different schools/dates/quantities - those rows are saved with import_flag set so they can
--     be rectified later;
--   * rows whose invoice already exists in the system (same or different details), exact repeats in the
--     file, invalid rows and rows needing product review are EXCLUDED and listed in 'issues'.
-- p_skip_problems=false keeps the old all-or-nothing behaviour.

alter table public.company_invoice_items add column if not exists import_flag text;

create or replace function public.fn__company_import_plan(p_rows jsonb, p_allow_multi boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare rep jsonb; v_skip int[]; v_flag int[]; v_dup int[];
begin
  rep := public.fn__company_upload_analyze(p_rows, p_allow_multi);
  select coalesce(array_agg((i->>'row')::int) filter (where i->>'status' <> 'conflict_in_file'), '{}'),
         coalesce(array_agg((i->>'row')::int) filter (where i->>'status' = 'conflict_in_file'), '{}')
    into v_skip, v_flag
  from jsonb_array_elements(rep->'issues') i;
  -- same invoice + school + product repeated inside the file: keep the first row only
  select coalesce(array_agg(rn), '{}') into v_dup from (
    select rn, row_number() over (partition by k, pid, sid order by rn) r
    from public.fn__company_upload_parse(p_rows) where invalid_reason is null and rn = any (v_flag)) z
  where r > 1;
  v_skip := v_skip || v_dup;
  v_flag := array(select x from unnest(v_flag) x where x <> all (v_skip));
  return jsonb_build_object('report', rep, 'skip', to_jsonb(v_skip), 'flag', to_jsonb(v_flag),
    'will_import', jsonb_array_length(p_rows) - coalesce(array_length(v_skip,1),0));
end $$;

drop function if exists public.fn_validate_company_invoice_upload(jsonb, boolean);
create or replace function public.fn_validate_company_invoice_upload(
  p_rows jsonb, p_allow_multi_product boolean default false, p_skip_problems boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare plan jsonb;
begin
  if not public.fn_is_admin() then raise exception 'Not authorized.'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Upload must be a JSON array of rows.'; end if;
  if not p_skip_problems then
    return public.fn__company_upload_analyze(p_rows, p_allow_multi_product) || jsonb_build_object('imported', false);
  end if;
  plan := public.fn__company_import_plan(p_rows, p_allow_multi_product);
  return (plan->'report') || jsonb_build_object('can_import', (plan->>'will_import')::int > 0,
    'will_import', (plan->>'will_import')::int, 'flagged_rows', jsonb_array_length(plan->'flag'),
    'excluded_rows', jsonb_array_length(plan->'skip'), 'skip_problems', true, 'imported', false);
end $$;

drop function if exists public.fn_import_company_invoices(jsonb, boolean, boolean);
create or replace function public.fn_import_company_invoices(
  p_rows jsonb, p_allow_multi_product boolean default false, p_auto_certify boolean default true,
  p_skip_problems boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  rep jsonb; plan jsonb; g record; v_id uuid; n_inv int := 0; n_items int := 0; n_cert int := 0; n_ins int;
  created jsonb := '[]'::jsonb; sids jsonb; v_skip int[] := '{}'; v_flag int[] := '{}';
begin
  if not public.fn_is_admin() then raise exception 'Not authorized.'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Upload must be a JSON array of rows.'; end if;

  for g in
    select distinct public.fn_norm_invoice(e->>'invoice_number') as k
    from jsonb_array_elements(p_rows) e
    where public.fn_norm_invoice(e->>'invoice_number') is not null
    order by 1
  loop
    perform pg_advisory_xact_lock(hashtextextended('company_invoice|'||g.k, 0));
  end loop;

  if p_skip_problems then
    plan := public.fn__company_import_plan(p_rows, p_allow_multi_product);
    rep := plan->'report';
    v_skip := array(select (x)::int from jsonb_array_elements_text(plan->'skip') x);
    v_flag := array(select (x)::int from jsonb_array_elements_text(plan->'flag') x);
    if (plan->>'will_import')::int <= 0 then
      return rep || jsonb_build_object('imported', false, 'message', 'Nothing was imported - every row has a problem. See the issues list.');
    end if;
  else
    rep := public.fn__company_upload_analyze(p_rows, p_allow_multi_product);
    if not (rep->>'can_import')::boolean then
      return rep || jsonb_build_object('imported', false,
        'message', 'Nothing was imported. Fix or remove the rows listed under issues and upload again.');
    end if;
  end if;

  for g in
    select k, pid, (array_agg(inv_raw order by rn))[1] as inv_raw, min(inv_date) as inv_date,
           min(del_date) as del_date, (array_agg(remarks_in order by rn))[1] as remarks_in
    from public.fn__company_upload_parse(p_rows)
    where invalid_reason is null and rn <> all (v_skip)
    group by k, pid
    order by min(rn)
  loop
    insert into public.company_invoices (invoice_number, invoice_date, delivery_date, remarks, entered_by, product_id)
    values (g.inv_raw, g.inv_date, g.del_date, g.remarks_in, auth.uid(), g.pid)
    returning id into v_id;
    n_inv := n_inv + 1;

    insert into public.company_invoice_items (invoice_id, school_id, product_id, quantity, unit, remarks, import_flag)
    select v_id, p.sid, p.pid, p.qty, coalesce(p.unit_in, p.unit_name), p.remarks_in,
           case when p.rn = any (v_flag) then format('FLAG: invoice number reused in the company file for a different school/date/quantity (delivery %s). Needs rectification.', p.del_date) end
    from public.fn__company_upload_parse(p_rows) p
    where p.invalid_reason is null and p.k = g.k and p.pid = g.pid and p.rn <> all (v_skip);
    get diagnostics n_ins = row_count;
    n_items := n_items + n_ins;

    select coalesce(jsonb_agg(p.sid), '[]'::jsonb) into sids
    from public.fn__company_upload_parse(p_rows) p
    where p.invalid_reason is null and p.k = g.k and p.pid = g.pid and p.rn <> all (v_skip);
    created := created || jsonb_build_object('invoice_id', v_id, 'invoice_number', g.inv_raw,
                                             'product_id', g.pid, 'school_ids', sids);

    if p_auto_certify then
      n_cert := n_cert + coalesce(public.fn_auto_certify_for_invoice(v_id), 0);
    end if;
  end loop;

  return rep || jsonb_build_object('imported', true, 'invoices_created', n_inv, 'items_created', n_items,
                                   'flagged_rows', coalesce(array_length(v_flag,1),0),
                                   'excluded_rows', coalesce(array_length(v_skip,1),0),
                                   'auto_certified', n_cert, 'created', created);
end $$;

grant execute on function public.fn_validate_company_invoice_upload(jsonb, boolean, boolean) to authenticated;
grant execute on function public.fn_import_company_invoices(jsonb, boolean, boolean, boolean) to authenticated;
