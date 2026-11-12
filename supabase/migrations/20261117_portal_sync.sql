-- Portal (smp26.pesrp.edu.pk) data pulled by the extractor straight into Supabase.
-- No audit triggers on purpose (keeps storage small). Only the service role may write.

create table if not exists public.portal_sync_runs (
  id bigserial primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  shard text,
  schools_total int, schools_ok int, rows_receipts int default 0, rows_consumption int default 0,
  status text, note text
);

create table if not exists public.portal_receipts (
  id bigserial primary key,
  emis_code text not null,
  product text not null,                 -- 'milk' | 'biscuit'
  receipt_date date not null,
  quantity numeric,
  challan_no text,
  challan_norm text not null default '',
  has_image boolean,
  run_id bigint references public.portal_sync_runs(id) on delete set null,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  unique (emis_code, product, receipt_date, challan_norm)
);
create index if not exists portal_receipts_challan_idx on public.portal_receipts (challan_norm, product);

create table if not exists public.portal_consumption (
  id bigserial primary key,
  emis_code text not null,
  product text not null,
  cons_date date not null,
  received numeric, present_stock numeric, consumption numeric, remaining numeric,
  run_id bigint references public.portal_sync_runs(id) on delete set null,
  last_seen timestamptz not null default now(),
  unique (emis_code, product, cons_date)
);

alter table public.portal_sync_runs  enable row level security;
alter table public.portal_receipts   enable row level security;
alter table public.portal_consumption enable row level security;

drop policy if exists portal_runs_read on public.portal_sync_runs;
create policy portal_runs_read on public.portal_sync_runs for select to authenticated using (public.fn_is_admin());

drop policy if exists portal_receipts_read on public.portal_receipts;
create policy portal_receipts_read on public.portal_receipts for select to authenticated
  using (public.fn_is_admin() or exists (select 1 from public.schools s where s.emis_code = portal_receipts.emis_code and s.assigned_aeo_id = auth.uid()));

drop policy if exists portal_cons_read on public.portal_consumption;
create policy portal_cons_read on public.portal_consumption for select to authenticated
  using (public.fn_is_admin() or exists (select 1 from public.schools s where s.emis_code = portal_consumption.emis_code and s.assigned_aeo_id = auth.uid()));

grant select on public.portal_sync_runs, public.portal_receipts, public.portal_consumption to authenticated;

-- p_run: {run_id?, shard, schools_total, schools_ok, status, note, finish?:bool}
-- p_receipts: [{emis, product, date, qty, challan}]
-- p_consumption: [{emis, product, date, received, present, consumption, remaining}]
create or replace function public.fn_portal_import(p_run jsonb, p_receipts jsonb default '[]', p_consumption jsonb default '[]')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_run bigint; nr int := 0; nc int := 0; x int;
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then
    raise exception 'service role only';
  end if;
  v_run := nullif(p_run->>'run_id','')::bigint;
  if v_run is null then
    insert into portal_sync_runs(shard, schools_total, status, note)
    values (p_run->>'shard', nullif(p_run->>'schools_total','')::int, 'running', p_run->>'note') returning id into v_run;
  end if;

  with src as (
    select distinct on (e, pr, d, cn) e, pr, d, q, ch, cn, im from (
      select btrim(r->>'emis') e, lower(btrim(r->>'product')) pr, (r->>'date')::date d,
             nullif(regexp_replace(coalesce(r->>'qty',''), '[^0-9.\-]', '', 'g'), '')::numeric q,
             nullif(btrim(r->>'challan'), '') ch,
             public.fn_norm_invoice(coalesce(r->>'challan','')) cn,
             (r->>'has_image')::boolean im
        from jsonb_array_elements(p_receipts) r
       where r->>'date' is not null and r->>'emis' ~ '^\d{8}$' and r->>'product' is not null) t)
  insert into portal_receipts(emis_code, product, receipt_date, quantity, challan_no, challan_norm, has_image, run_id)
  select e, pr, d, q, ch, coalesce(cn,''), im, v_run from src
  on conflict (emis_code, product, receipt_date, challan_norm)
  do update set quantity = excluded.quantity, challan_no = excluded.challan_no, has_image = excluded.has_image,
                run_id = excluded.run_id, last_seen = now();
  get diagnostics nr = row_count;

  with src as (
    select distinct on (e, pr, d) e, pr, d, rc, ps, cs, rm from (
      select btrim(r->>'emis') e, lower(btrim(r->>'product')) pr, (r->>'date')::date d,
             nullif(regexp_replace(coalesce(r->>'received',''), '[^0-9.\-]', '', 'g'), '')::numeric rc,
             nullif(regexp_replace(coalesce(r->>'present',''), '[^0-9.\-]', '', 'g'), '')::numeric ps,
             nullif(regexp_replace(coalesce(r->>'consumption',''), '[^0-9.\-]', '', 'g'), '')::numeric cs,
             nullif(regexp_replace(coalesce(r->>'remaining',''), '[^0-9.\-]', '', 'g'), '')::numeric rm
        from jsonb_array_elements(p_consumption) r
       where r->>'date' is not null and r->>'emis' ~ '^\d{8}$' and r->>'product' is not null) t)
  insert into portal_consumption(emis_code, product, cons_date, received, present_stock, consumption, remaining, run_id)
  select e, pr, d, rc, ps, cs, rm, v_run from src
  on conflict (emis_code, product, cons_date)
  do update set received = excluded.received, present_stock = excluded.present_stock,
                consumption = excluded.consumption, remaining = excluded.remaining, run_id = excluded.run_id, last_seen = now();
  get diagnostics nc = row_count;

  update portal_sync_runs set rows_receipts = rows_receipts + nr, rows_consumption = rows_consumption + nc,
         schools_ok = coalesce(nullif(p_run->>'schools_ok','')::int, schools_ok),
         status = case when coalesce((p_run->>'finish')::boolean, false) then coalesce(p_run->>'status','done') else status end,
         finished_at = case when coalesce((p_run->>'finish')::boolean, false) then now() else finished_at end,
         note = coalesce(p_run->>'note', note)
   where id = v_run;
  return jsonb_build_object('run_id', v_run, 'receipts', nr, 'consumption', nc);
end $$;
revoke all on function public.fn_portal_import(jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.fn_portal_import(jsonb, jsonb, jsonb) to service_role;

-- Portal vs AEO-entered receipts, matched on school + product + normalised challan/invoice number
create or replace view public.v_portal_vs_aeo_receipts with (security_invoker = true) as
select p.emis_code, s.school_name, p.product, p.receipt_date as portal_date, p.challan_no as portal_challan,
       p.quantity as portal_qty, a.receipt_date as aeo_date, a.invoice_number as aeo_invoice, a.quantity_received as aeo_qty,
       case when a.id is null then 'missing_in_aeo'
            when a.quantity_received is distinct from p.quantity then 'qty_differs'
            when a.receipt_date <> p.receipt_date then 'date_differs' else 'match' end as result
  from public.portal_receipts p
  left join public.schools s on s.emis_code = p.emis_code
  left join public.products pr on lower(pr.product_name) like '%' || p.product || '%'
  left join public.school_receipts a on a.school_id = s.id and a.product_id = pr.id
        and coalesce(a.status,'active') not in ('void','voided','cancelled')
        and public.fn_norm_invoice(coalesce(a.invoice_number,'')) = p.challan_norm and p.challan_norm <> '';

-- keep cron history small (it grows ~1,900 rows/day)
select cron.unschedule('prune_cron_history') where exists (select 1 from cron.job where jobname = 'prune_cron_history');
select cron.schedule('prune_cron_history', '15 21 * * *', $$delete from cron.job_run_details where end_time < now() - interval '3 days'$$);
