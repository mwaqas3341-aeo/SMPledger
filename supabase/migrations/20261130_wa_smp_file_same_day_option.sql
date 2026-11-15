alter table public.wa_collect_groups add column if not exists smp_file_day text not null default 'previous' check (smp_file_day in ('previous','same'));

create or replace function public.fn_wa_smp_build(p_group text, p_date date)
returns table(missing_schools int, total_schools int, fetch_at timestamptz, stale boolean, message_text text, columns jsonb, rows jsonb, file_name text)
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $f$
declare g public.wa_collect_groups; v_ids uuid[]; v_fetch timestamptz; v_today date := (now() at time zone 'Asia/Karachi')::date;
        v_start timestamptz := (v_today::timestamp at time zone 'Asia/Karachi');
        v_total int; v_same boolean; v_miss int; v_rows jsonb; v_lines text; v_head text; v_stale boolean; v_stale_n int; v_text text; v_names text; v_link text; v_prod text;
begin
  select * into g from public.wa_collect_groups where group_jid = p_group;
  if not found then raise exception 'Group not set up'; end if;
  v_same := coalesce(g.smp_file_day, 'previous') = 'same';
  -- previous-day report: the SMP fetch should be from today; same-day report: from within 3 hours before the send time
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

  with prods as (select pr.id, pr.product_name from public.products pr where pr.active and public.fn_wa_collect_is_day(pr.id, p_date)),
  miss as (
    select s.id school_id, s.emis_code, s.school_name, s.wing, m.name markaz, m.tehsil, pr.product_name,
           (select to_char(max(st.last_synced) at time zone 'Asia/Karachi', 'DD-MM-YYYY HH12:MI AM') from public.portal_sync_state st where st.emis_code = s.emis_code) fetched,
           (select sum(c.quantity) from public.consumption c where c.school_id = s.id and c.product_id = pr.id and c.consumption_date = p_date and c.status = 'active') aeo_qty
      from public.schools s join public.markaz m on m.id = s.markaz_id cross join prods pr
     where s.id = any(v_ids)
       and exists (select 1 from public.portal_sync_state st where st.emis_code = s.emis_code and lower(pr.product_name) like '%' || st.product || '%')
       and not exists (select 1 from public.portal_consumption pc where pc.emis_code = s.emis_code and lower(pr.product_name) like '%' || pc.product || '%'
                          and pc.cons_date = p_date and coalesce(pc.consumption, 0) > 0))
  select count(distinct school_id)::int,
         coalesce(jsonb_agg(jsonb_build_array(rn, tehsil, markaz, emis_code, school_name, coalesce(wing, ''), to_char(p_date, 'DD-MM-YYYY'), product_name,
                  coalesce(aeo_qty, 0), 'Not reported on SMP', coalesce(fetched, '')) order by rn), '[]'::jsonb)
    into v_miss, v_rows
    from (select m.*, row_number() over (order by tehsil, markaz, school_name, product_name) rn from miss m) x;

  with prods as (select pr.id, pr.product_name from public.products pr where pr.active and public.fn_wa_collect_is_day(pr.id, p_date)),
  miss as (
    select s.id school_id, s.emis_code, s.school_name, m.name markaz, pr.product_name
      from public.schools s join public.markaz m on m.id = s.markaz_id cross join prods pr
     where s.id = any(v_ids)
       and exists (select 1 from public.portal_sync_state st where st.emis_code = s.emis_code and lower(pr.product_name) like '%' || st.product || '%')
       and not exists (select 1 from public.portal_consumption pc where pc.emis_code = s.emis_code and lower(pr.product_name) like '%' || pc.product || '%'
                          and pc.cons_date = p_date and coalesce(pc.consumption, 0) > 0)),
  sch as (select markaz, school_id, school_name, emis_code, string_agg(product_name, ', ' order by product_name) prods from miss group by 1, 2, 3, 4),
  per as (select markaz, count(*) n, string_agg('  • ' || school_name || ' (' || emis_code || ') – ' || prods, E'\n' order by school_name) lst from sch group by markaz)
  select string_agg('*' || markaz || '* (' || n || ')' || E'\n' || lst, E'\n\n' order by markaz) into v_lines from per;

  select string_agg(pr.product_name, ' & ' order by pr.product_name) into v_prod from public.products pr where pr.active and public.fn_wa_collect_is_day(pr.id, p_date);
  if g.scope_type = 'markaz' then
    select string_agg(m.name, ', ' order by m.name) into v_names from public.markaz m where m.id = any(g.markaz_ids);
    v_head := 'Tehsil: ' || coalesce(g.tehsil, '-') || E'\nMarkaz: ' || coalesce(v_names, '-');
  else v_head := 'Tehsil: ' || coalesce(g.tehsil, '-'); end if;
  select app_link into v_link from public.wa_settings where id;

  if length(coalesce(v_lines, '')) > 3000 then v_lines := left(v_lines, 3000) || E'\n… more schools are in the Excel file'; end if;
  v_text := '*SMP Missing Consumption – Head Teachers (SMP app)*' || E'\n' || v_head || E'\n' ||
            'Consumption date: ' || to_char(p_date, 'FMDay, DD Mon YYYY') || case when v_same then ' (today, as reported so far)' else '' end || coalesce(' – ' || v_prod, '') || E'\n' ||
            '📡 SMP web portal data fetched: ' || coalesce(to_char(v_fetch at time zone 'Asia/Karachi', 'DD Mon YYYY, FMHH12:MI AM') || ' (Pakistan time)', 'not available') || E'\n' ||
            case when v_stale then (case when v_same then E'⚠ The SMP data was not refreshed recently, so entries made since that time are not included.\n' else E'⚠ Today''s SMP refresh had not finished; these figures are from the last fetch.\n' end) else '' end ||
            case when v_stale_n > 0 and not v_stale then '⚠ ' || v_stale_n || E' school(s) could not be refreshed in the latest fetch; their figures are from an earlier fetch.\n' else '' end ||
            case when v_miss = 0 then E'\nAll ' || v_total || ' schools have reported their consumption on SMP' || case when v_same then ' as of the fetch time above.' else '.' end || ' Thank you.'
                 else 'Schools with consumption not reported on SMP: ' || v_miss || ' of ' || v_total || E'\n\n' || v_lines ||
                      E'\n\nHead teachers are requested to update ' || case when v_same then 'today''s' else 'the' end || ' consumption on the SMP app. The Excel list is attached.' end;
  return query select v_miss, v_total, v_fetch, v_stale, v_text,
    case when v_miss = 0 then null else jsonb_build_array('Sr', 'Tehsil', 'Markaz', 'EMIS Code', 'School', 'Wing', 'Consumption date', 'Product', 'Recorded by AEO (SMP Ledger)', 'Status', 'SMP data fetched (Pakistan time)') end,
    case when v_miss = 0 then null else v_rows end,
    case when v_miss = 0 then null else 'SMP-missing-consumption_' || to_char(p_date, 'YYYY-MM-DD') || '_' || regexp_replace(coalesce(g.label, 'group'), '[^A-Za-z0-9]+', '-', 'g') || '.xlsx' end;
end $f$;

create or replace function public.fn_wa_smp_enqueue_due() returns integer
language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi'; v_today date; v_day date; g record; b record;
        v_n int := 0; v_open boolean; v_fresh boolean; v_any boolean; v_since timestamptz;
begin
  select * into ws from public.wa_settings where id;
  if not found or not ws.enabled or ws.emergency_stop then return 0; end if;
  v_today := v_now::date;
  select coalesce(is_open, true) into v_open from public.program_state where id;
  if v_open is false then return 0; end if;
  for g in select * from public.wa_collect_groups where active and smp_file_time is not null loop
    if v_now::time < g.smp_file_time then continue; end if;
    v_day := case when coalesce(g.smp_file_day, 'previous') = 'same' then v_today else v_today - 1 end;
    v_since := case when coalesce(g.smp_file_day, 'previous') = 'same' then ((v_today + g.smp_file_time) - interval '3 hours') at time zone 'Asia/Karachi'
                     else v_today::timestamp at time zone 'Asia/Karachi' end;
    select exists (select 1 from public.portal_sync_runs where status in ('done', 'partial') and finished_at >= v_since) into v_fresh;
    select exists (select 1 from public.products pr where pr.active and public.fn_wa_collect_is_day(pr.id, v_day)) into v_any;
    if exists (select 1 from public.wa_smp_jobs j where j.group_jid = g.group_jid and j.report_date = v_day) then continue; end if;
    if not v_any then continue; end if;                                   
    if not v_fresh and v_now < v_today::timestamp + g.smp_file_time + interval '3 hours' then continue; end if;   -- wait (up to 3 h) for today's SMP fetch
    begin
      select * into b from public.fn_wa_smp_build(g.group_jid, v_day);
      insert into public.wa_smp_jobs(group_jid, report_date, message_text, file_name, columns, rows, missing_schools, total_schools, fetch_at, stale)
      values (g.group_jid, v_day, b.message_text, b.file_name, b.columns, b.rows, b.missing_schools, b.total_schools, b.fetch_at, b.stale)
      on conflict (group_jid, report_date) do nothing;
      v_n := v_n + 1;
    exception when others then
      insert into public.wa_logs(event, error_message) values ('enqueue_error', left('smp file ' || g.group_jid || ': ' || sqlerrm, 500));
    end;
  end loop;
  return v_n;
end $f$;

-- Admin: queue yesterday's report for a group right now (test / resend)
create or replace function public.fn_wa_smp_queue_now(p_group text) returns text
language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare v_day date; b record;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  select case when coalesce(smp_file_day, 'previous') = 'same' then (now() at time zone 'Asia/Karachi')::date else (now() at time zone 'Asia/Karachi')::date - 1 end into v_day from public.wa_collect_groups where group_jid = p_group;
  if v_day is null then raise exception 'Group not set up'; end if;
  if exists (select 1 from public.wa_smp_jobs where group_jid = p_group and report_date = v_day and status = 'processing') then raise exception 'It is being sent right now'; end if;
  select * into b from public.fn_wa_smp_build(p_group, v_day);
  insert into public.wa_smp_jobs(group_jid, report_date, message_text, file_name, columns, rows, missing_schools, total_schools, fetch_at, stale, status, attempt_count, created_at, last_error)
  values (p_group, v_day, b.message_text, b.file_name, b.columns, b.rows, b.missing_schools, b.total_schools, b.fetch_at, b.stale, 'queued', 0, now(), null)
  on conflict (group_jid, report_date) do update set message_text = excluded.message_text, file_name = excluded.file_name, columns = excluded.columns, rows = excluded.rows,
    missing_schools = excluded.missing_schools, total_schools = excluded.total_schools, fetch_at = excluded.fetch_at, stale = excluded.stale, status = 'queued', attempt_count = 0, created_at = now(), last_error = null, sent_at = null;
  return b.message_text;
end $f$;

-- Admin: preview the text without queuing
create or replace function public.fn_wa_smp_preview(p_group text) returns text
language plpgsql security definer set search_path to 'public', 'pg_temp' as $f$
declare b record; v_day date;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  select case when coalesce(smp_file_day, 'previous') = 'same' then (now() at time zone 'Asia/Karachi')::date else (now() at time zone 'Asia/Karachi')::date - 1 end into v_day from public.wa_collect_groups where group_jid = p_group;
  select * into b from public.fn_wa_smp_build(p_group, v_day);
  return b.message_text;
end $f$;

