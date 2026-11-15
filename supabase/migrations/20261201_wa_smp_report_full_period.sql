create table if not exists public.wa_smp_settings (id boolean primary key default true check (id), report_start date not null);
insert into public.wa_smp_settings(id, report_start) values (true, date '2026-09-28') on conflict (id) do nothing;
alter table public.wa_smp_settings enable row level security;
drop policy if exists wa_smp_settings_admin on public.wa_smp_settings;
create policy wa_smp_settings_admin on public.wa_smp_settings for all to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());

create or replace function public.fn_wa_smp_build(p_group text, p_date date)
returns table(missing_schools int, total_schools int, fetch_at timestamptz, stale boolean, message_text text, columns jsonb, rows jsonb, file_name text)
language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare g public.wa_collect_groups; v_ids uuid[]; v_fetch timestamptz; v_today date := (now() at time zone 'Asia/Karachi')::date;
        v_start timestamptz; v_from date; v_total int; v_same boolean; v_miss int; v_entries int; v_rows jsonb; v_lines text; v_head text;
        v_stale boolean; v_stale_n int; v_text text; v_names text; v_link text;
begin
  select * into g from public.wa_collect_groups where group_jid = p_group;
  if not found then raise exception 'Group not set up'; end if;
  select coalesce((select report_start from public.wa_smp_settings where id), date '2026-09-28') into v_from;
  v_same := coalesce(g.smp_file_day, 'previous') = 'same';
  v_start := ((v_today + coalesce(g.smp_file_time, time '15:00')) - case when v_same then interval '3 hours' else coalesce(g.smp_file_time, time '15:00') - time '00:00' end) at time zone 'Asia/Karachi';
  select coalesce(array_agg(s.id), '{}'::uuid[]) into v_ids
    from public.schools s join public.markaz m on m.id = s.markaz_id
   where s.active and (case when g.scope_type = 'markaz' then m.id = any(g.markaz_ids)
                            else m.tehsil = g.tehsil and (g.district is null or m.district = g.district) end)
     and exists (select 1 from public.portal_sync_state st where st.emis_code = s.emis_code);
  select count(*) into v_total from unnest(v_ids);
  v_fetch := public.fn_portal_last_sync();
  v_stale := v_fetch is null or v_fetch < v_start;
  select count(distinct s.id) into v_stale_n from public.schools s
   where s.id = any(v_ids) and coalesce((select max(st.last_synced) from public.portal_sync_state st where st.emis_code = s.emis_code), '-infinity') < v_start;

  drop table if exists _smp_miss;
  create temp table _smp_miss on commit drop as
  with days as (select d::date d from generate_series(v_from, p_date, interval '1 day') d),
  sched as (select pr.id product_id, pr.product_name, d.d from public.products pr cross join days d
             where pr.active and public.fn_wa_collect_is_day(pr.id, d.d)
               and exists (select 1 from public.portal_consumption pc where lower(pr.product_name) like '%' || pc.product || '%' and pc.cons_date = d.d and coalesce(pc.consumption, 0) > 0))  -- a day nobody reported at all is a holiday / no-data day, not a gap
  select s.id school_id, s.emis_code, s.school_name, coalesce(s.wing, '') wing, m.name markaz, m.tehsil, sc.product_name, sc.d,
         (select to_char(max(st.last_synced) at time zone 'Asia/Karachi', 'DD-MM-YYYY HH12:MI AM') from public.portal_sync_state st where st.emis_code = s.emis_code) fetched,
         (select sum(c.quantity) from public.consumption c where c.school_id = s.id and c.product_id = sc.product_id and c.consumption_date = sc.d and c.status = 'active') aeo_qty
    from public.schools s join public.markaz m on m.id = s.markaz_id cross join sched sc
   where s.id = any(v_ids)
     and exists (select 1 from public.portal_sync_state st where st.emis_code = s.emis_code and lower(sc.product_name) like '%' || st.product || '%')
     and not exists (select 1 from public.portal_consumption pc where pc.emis_code = s.emis_code and lower(sc.product_name) like '%' || pc.product || '%'
                        and pc.cons_date = sc.d and coalesce(pc.consumption, 0) > 0);

  select count(distinct school_id)::int, count(*)::int into v_miss, v_entries from _smp_miss;
  select coalesce(jsonb_agg(jsonb_build_array(rn, tehsil, markaz, emis_code, school_name, wing, to_char(d, 'DD-MM-YYYY'), product_name,
           coalesce(aeo_qty, 0), 'Not reported on SMP', coalesce(fetched, '')) order by rn), '[]'::jsonb) into v_rows
    from (select m.*, row_number() over (order by tehsil, markaz, school_name, emis_code, product_name, d) rn from _smp_miss m) x;

  with pm as (select markaz, school_id, school_name, emis_code, product_name, count(*) n,
                     string_agg(mdates, '; ' order by mk) dts
                from (select markaz, school_id, school_name, emis_code, product_name, to_char(d, 'YYYYMM') mk,
                             string_agg(to_char(d, 'FMDD'), ', ' order by d) || ' ' || to_char(min(d), 'Mon') mdates, count(*) c
                        from _smp_miss group by 1, 2, 3, 4, 5, 6) t
               group by 1, 2, 3, 4, 5),
  sch as (select markaz, school_id, school_name, emis_code, sum(n) n,
                 string_agg(product_name || ' (' || n || '): ' || dts, E'\n     ' order by product_name) det
            from pm group by 1, 2, 3, 4),
  per as (select markaz, count(*) ns, sum(n) ne, string_agg('  • ' || school_name || ' (' || emis_code || ') – ' || n || ' missing' || E'\n     ' || det, E'\n' order by school_name) lst from sch group by markaz)
  select string_agg('*' || markaz || '* – ' || ns || ' school(s), ' || ne || ' entries' || E'\n' || lst, E'\n\n' order by markaz) into v_lines from per;

  if g.scope_type = 'markaz' then
    select string_agg(m.name, ', ' order by m.name) into v_names from public.markaz m where m.id = any(g.markaz_ids);
    v_head := 'Tehsil: ' || coalesce(g.tehsil, '-') || E'\nMarkaz: ' || coalesce(v_names, '-');
  else v_head := 'Tehsil: ' || coalesce(g.tehsil, '-'); end if;
  if length(coalesce(v_lines, '')) > 2800 then v_lines := left(v_lines, 2800) || E'\n… more schools and dates are in the Excel file'; end if;
  v_text := '*SMP Missing Consumption – Head Teachers (SMP app)*' || E'\n' || v_head || E'\n' ||
            'Period: ' || to_char(v_from, 'DD Mon YYYY') || ' to ' || to_char(p_date, 'DD Mon YYYY') || case when v_same then ' (today as reported so far)' else '' end || ' – all scheduled consumption days' || E'\n' ||
            '📡 SMP web portal data fetched: ' || coalesce(to_char(v_fetch at time zone 'Asia/Karachi', 'DD Mon YYYY, FMHH12:MI AM') || ' (Pakistan time)', 'not available') || E'\n' ||
            case when v_stale then (case when v_same then E'⚠ The SMP data was not refreshed recently, so entries made since that time are not included.\n' else E'⚠ Today''s SMP refresh had not finished; these figures are from the last fetch.\n' end) else '' end ||
            case when v_stale_n > 0 and not v_stale then '⚠ ' || v_stale_n || E' school(s) could not be refreshed in the latest fetch; their figures are from an earlier fetch.\n' else '' end ||
            case when v_miss = 0 then E'\nAll ' || v_total || ' schools have reported all their consumption on SMP for this period. Thank you.'
                 else 'Schools with consumption not reported on SMP: ' || v_miss || ' of ' || v_total || ' (' || v_entries || E' entries)\n\n' || v_lines ||
                      E'\n\nHead teachers are requested to update the missing consumption on the SMP app. The Excel list is attached.' end;
  return query select v_miss, v_total, v_fetch, v_stale, v_text,
    case when v_miss = 0 then null else jsonb_build_array('Sr', 'Tehsil', 'Markaz', 'EMIS Code', 'School', 'Wing', 'Consumption date', 'Product', 'Recorded by AEO (SMP Ledger)', 'Status', 'SMP data fetched (Pakistan time)') end,
    case when v_miss = 0 then null else v_rows end,
    case when v_miss = 0 then null else 'SMP-missing-consumption_' || to_char(v_from, 'YYYY-MM-DD') || '_to_' || to_char(p_date, 'YYYY-MM-DD') || '_' || regexp_replace(coalesce(g.label, 'group'), '[^A-Za-z0-9]+', '-', 'g') || '.xlsx' end;
end $f$;
revoke all on function public.fn_wa_smp_build(text, date) from public, anon, authenticated;
