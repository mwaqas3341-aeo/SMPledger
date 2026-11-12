-- 1) Where the runner left off, per school + product.  2) Consumption issues (portal vs AEO) kept for rectification.

create table if not exists public.portal_sync_state (
  emis_code text not null,
  product text not null,
  first_cons_date date,
  last_cons_date date,
  last_receipt_date date,
  last_synced timestamptz not null default now(),
  primary key (emis_code, product)
);
alter table public.portal_sync_state enable row level security;
drop policy if exists portal_state_read on public.portal_sync_state;
create policy portal_state_read on public.portal_sync_state for select to authenticated using (public.fn_is_admin_or_tr());
grant select on public.portal_sync_state to authenticated;

create table if not exists public.consumption_issues (
  id bigserial primary key,
  school_id uuid not null references public.schools(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  emis_code text not null,
  cons_date date not null,
  issue text not null check (issue in ('qty_differs','head_missing','aeo_missing')),
  head_qty numeric,
  aeo_qty numeric,
  status text not null default 'open' check (status in ('open','resolved')),
  detected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (school_id, product_id, cons_date)
);
create index if not exists consumption_issues_open_idx on public.consumption_issues (status, cons_date);
alter table public.consumption_issues enable row level security;
drop policy if exists cons_issues_read on public.consumption_issues;
create policy cons_issues_read on public.consumption_issues for select to authenticated
  using (public.fn_is_admin_or_tr() or exists (select 1 from public.schools s where s.id = consumption_issues.school_id and s.assigned_aeo_id = auth.uid()));
grant select on public.consumption_issues to authenticated;

-- Compare portal consumption with what the AEO side recorded.  Dates inside the window and older than the grace days only.
create or replace function public.fn_portal_compare_consumption(p_window int default 30, p_grace int default 2)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_new int := 0; v_res int := 0; v_purged int := 0; v_from date := current_date - greatest(p_window, 1); v_to date := current_date - greatest(p_grace, 0);
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') and not public.fn_is_admin() then
    raise exception 'not allowed';
  end if;

  create temp table _cmp on commit drop as
  with scope as (
    select s.id school_id, s.emis_code, pr.id product_id, st.product, st.first_cons_date
      from public.portal_sync_state st
      join public.schools s on s.emis_code = st.emis_code
      join public.products pr on lower(pr.product_name) like '%' || st.product || '%'),
  p as (select sc.school_id, sc.product_id, pc.cons_date d, pc.consumption q
          from public.portal_consumption pc join scope sc on sc.emis_code = pc.emis_code and sc.product = pc.product),
  a as (select c.school_id, c.product_id, c.consumption_date d, sum(c.quantity) q
          from public.consumption c join scope sc on sc.school_id = c.school_id and sc.product_id = c.product_id
         where c.status = 'active' group by 1, 2, 3),
  f as (select coalesce(p.school_id, a.school_id) school_id, coalesce(p.product_id, a.product_id) product_id,
               coalesce(p.d, a.d) d, p.q pq, a.q aq
          from p full join a on a.school_id = p.school_id and a.product_id = p.product_id and a.d = p.d)
  select f.school_id, f.product_id, sc.emis_code, f.d, f.pq, f.aq,
         case when coalesce(f.pq,0) = 0 and coalesce(f.aq,0) = 0 then 'ok'
              when coalesce(f.pq,0) > 0 and coalesce(f.aq,0) = 0 then 'aeo_missing'
              when coalesce(f.aq,0) > 0 and coalesce(f.pq,0) = 0 then 'head_missing'
              when f.pq <> f.aq then 'qty_differs' else 'ok' end as res
    from f join scope sc on sc.school_id = f.school_id and sc.product_id = f.product_id
   where f.d between v_from and v_to and (sc.first_cons_date is null or f.d >= sc.first_cons_date);

  insert into public.consumption_issues(school_id, product_id, emis_code, cons_date, issue, head_qty, aeo_qty)
  select school_id, product_id, emis_code, d, res, pq, aq from _cmp where res <> 'ok'
  on conflict (school_id, product_id, cons_date) do update
    set issue = excluded.issue, head_qty = excluded.head_qty, aeo_qty = excluded.aeo_qty, updated_at = now(),
        status = 'open', resolved_at = null
    where (consumption_issues.issue, consumption_issues.head_qty, consumption_issues.aeo_qty, consumption_issues.status)
          is distinct from (excluded.issue, excluded.head_qty, excluded.aeo_qty, 'open');
  get diagnostics v_new = row_count;

  update public.consumption_issues i set status = 'resolved', resolved_at = now(), updated_at = now()
    from _cmp c where c.school_id = i.school_id and c.product_id = i.product_id and c.d = i.cons_date
     and c.res = 'ok' and i.status = 'open';
  get diagnostics v_res = row_count;

  -- matching entries are not kept: portal rows that agree with the AEO figure are dropped, as is anything past the window
  delete from public.portal_consumption pc using _cmp c
   where c.emis_code = pc.emis_code and c.d = pc.cons_date and c.res = 'ok'
     and exists (select 1 from public.products pr where pr.id = c.product_id and lower(pr.product_name) like '%' || pc.product || '%')
     and coalesce(c.pq,0) > 0;
  get diagnostics v_purged = row_count;
  delete from public.portal_consumption where cons_date < v_from - 5;

  return jsonb_build_object('issues_changed', v_new, 'resolved', v_res, 'matched_rows_dropped', v_purged);
end $$;
revoke all on function public.fn_portal_compare_consumption(int, int) from public, anon;
grant execute on function public.fn_portal_compare_consumption(int, int) to authenticated, service_role;

-- where the runner should start from
create or replace function public.fn_portal_watermarks()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('emis', emis_code, 'product', product,
            'cons', last_cons_date, 'receipt', last_receipt_date)) from public.portal_sync_state), '[]'::jsonb);
end $$;
revoke all on function public.fn_portal_watermarks() from public, anon, authenticated;
grant execute on function public.fn_portal_watermarks() to service_role;

-- import: also records the watermark and the schools that were fully read, then runs the comparison when the run finishes
do $$
declare d text;
begin
  select replace(pg_get_functiondef(p.oid), E'\r', '') into d from pg_proc p
   where p.proname = 'fn_portal_import' and p.pronamespace = 'public'::regnamespace;
  if d like '%portal_sync_state%' then return; end if;
  d := replace(d, E'  update portal_sync_runs set rows_receipts',
$x$  insert into portal_sync_state(emis_code, product, first_cons_date, last_cons_date, last_receipt_date)
  select e, pr, min(cd), max(cd), max(rd) from (
    select btrim(r->>'emis') e, lower(btrim(r->>'product')) pr, (r->>'date')::date cd, null::date rd
      from jsonb_array_elements(p_consumption) r where r->>'emis' ~ '^\d{8}$' and r->>'date' is not null
    union all
    select btrim(r->>'emis'), lower(btrim(r->>'product')), null, (r->>'date')::date
      from jsonb_array_elements(p_receipts) r where r->>'emis' ~ '^\d{8}$' and r->>'date' is not null
    union all   -- schools read completely, even if they had nothing new
    select btrim(x), pr, null, null from jsonb_array_elements_text(coalesce(p_run->'ok_emis', '[]'::jsonb)) x, (values ('milk'), ('biscuit')) v(pr)
  ) t group by e, pr
  on conflict (emis_code, product) do update set
    first_cons_date = least(portal_sync_state.first_cons_date, excluded.first_cons_date),
    last_cons_date = greatest(portal_sync_state.last_cons_date, excluded.last_cons_date),
    last_receipt_date = greatest(portal_sync_state.last_receipt_date, excluded.last_receipt_date),
    last_synced = now();
$x$ || E'\n  update portal_sync_runs set rows_receipts');
  d := replace(d, E'  return jsonb_build_object(''run_id'', v_run,',
    E'  if coalesce((p_run->>''finish'')::boolean, false) then perform public.fn_portal_compare_consumption(); end if;\n  return jsonb_build_object(''run_id'', v_run,');
  execute d;
end $$;
