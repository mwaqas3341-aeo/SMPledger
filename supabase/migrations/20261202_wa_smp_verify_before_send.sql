-- Before a missing-consumption report is sent, re-check ONLY the schools listed in it on the SMP dashboard.
-- Flow: due -> job 'verifying' + a request in wa_smp_verify (the schools in the draft list)
--       -> GitHub workflow "Portal verify" (every 5 min) claims the request, reads just those schools, pushes the data
--       -> fn_wa_smp_release_verifying() rebuilds the message/Excel from the fresh data and queues it for the worker.
-- If the re-check does not finish within 60 minutes, the report is rebuilt from the latest data and sent with a warning line.

do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.wa_smp_jobs'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%queued%' loop
    execute format('alter table public.wa_smp_jobs drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.wa_smp_jobs add constraint wa_smp_jobs_status_check check (status in ('verifying','queued','processing','sent','failed','cancelled'));
alter table public.wa_smp_jobs add column if not exists verify_id bigint, add column if not exists verify_deadline timestamptz, add column if not exists verified_at timestamptz, add column if not exists verify_result text;

create table if not exists public.wa_smp_verify (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','running','done','failed')),
  emis text[] not null default '{}',
  claimed_at timestamptz, finished_at timestamptz, schools_checked int, note text);
alter table public.wa_smp_verify enable row level security;
drop policy if exists wa_smp_verify_admin_read on public.wa_smp_verify;
create policy wa_smp_verify_admin_read on public.wa_smp_verify for select using (public.fn_is_admin());

-- create a report job; with missing schools it waits ('verifying') for the dashboard re-check, otherwise it is queued at once
create or replace function public.fn_wa_smp_start_job(p_group text, p_day date, p_replace boolean default false)
returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare b record; v_codes text[]; v_vid bigint; v_id uuid; v_status text;
begin
  select * into b from public.fn_wa_smp_build(p_group, p_day);
  select coalesce(array_agg(distinct r->>3), '{}') into v_codes from jsonb_array_elements(coalesce(b.rows, '[]'::jsonb)) r;
  if b.missing_schools > 0 and cardinality(v_codes) > 0 then
    select id into v_vid from public.wa_smp_verify where status = 'pending' and created_at > now() - interval '10 minutes' order by id desc limit 1 for update;
    if v_vid is null then insert into public.wa_smp_verify(emis) values (v_codes) returning id into v_vid;
    else update public.wa_smp_verify set emis = (select array_agg(distinct x) from unnest(emis || v_codes) x) where id = v_vid; end if;
    v_status := 'verifying';
  else v_status := 'queued'; end if;
  insert into public.wa_smp_jobs(group_jid, report_date, message_text, file_name, columns, rows, missing_schools, total_schools, fetch_at, stale, status, attempt_count, created_at, last_error, verify_id, verify_deadline, verified_at, verify_result)
  values (p_group, p_day, b.message_text, b.file_name, b.columns, b.rows, b.missing_schools, b.total_schools, b.fetch_at, b.stale, v_status, 0, now(), null,
          case when v_status = 'verifying' then v_vid end, case when v_status = 'verifying' then now() + interval '60 minutes' end, null, case when v_status = 'queued' then 'not needed' end)
  on conflict (group_jid, report_date) do update set message_text = excluded.message_text, file_name = excluded.file_name, columns = excluded.columns, rows = excluded.rows,
    missing_schools = excluded.missing_schools, total_schools = excluded.total_schools, fetch_at = excluded.fetch_at, stale = excluded.stale, status = excluded.status,
    attempt_count = 0, created_at = now(), last_error = null, sent_at = null, verify_id = excluded.verify_id, verify_deadline = excluded.verify_deadline, verified_at = null, verify_result = excluded.verify_result
    where p_replace
  returning id into v_id;
  return v_id;
end $$;

-- rebuild jobs whose re-check finished (or timed out) from the fresh data, then queue them for the worker
create or replace function public.fn_wa_smp_release_verifying()
returns integer language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare j record; v record; b record; v_txt text; v_note text; v_res text; v_n int := 0; v_when text;
begin
  for j in select * from public.wa_smp_jobs where status = 'verifying' for update skip locked loop
    select * into v from public.wa_smp_verify where id = j.verify_id;
    if v.id is not null and v.status in ('pending', 'running') and now() < j.verify_deadline then continue; end if;
    v_res := case when v.id is null or v.status in ('pending', 'running') then 'timeout'
                  when v.status = 'failed' then 'failed'
                  when coalesce(v.schools_checked, 0) < cardinality(v.emis) then 'partial' else 'ok' end;
    begin
      select * into b from public.fn_wa_smp_build(j.group_jid, j.report_date);
      v_when := to_char(now() at time zone 'Asia/Karachi', 'DD Mon YYYY, FMHH12:MI AM');
      v_note := case v_res
        when 'ok' then '🔄 Re-checked on the SMP dashboard just before sending (' || v_when || ', Pakistan time).'
        when 'partial' then '⚠ Re-checked on the SMP dashboard just before sending, but ' || (cardinality(v.emis) - coalesce(v.schools_checked, 0)) || ' school(s) could not be read; they may have been updated since the last fetch.'
        else '⚠ The SMP dashboard could not be re-checked just before sending; schools updated after the last fetch may still be listed.' end;
      v_txt := regexp_replace(b.message_text, E'^([^\n]*\n)', '\1' || v_note || E'\n');
      update public.wa_smp_jobs set message_text = v_txt, file_name = b.file_name, columns = b.columns, rows = b.rows, missing_schools = b.missing_schools,
        total_schools = b.total_schools, fetch_at = b.fetch_at, stale = b.stale, status = 'queued', created_at = now(), verified_at = now(), verify_result = v_res where id = j.id;
      v_n := v_n + 1;
    exception when others then
      update public.wa_smp_jobs set status = 'failed', last_error = left('release: ' || sqlerrm, 500) where id = j.id;
    end;
  end loop;
  return v_n;
end $$;

-- called by the "Portal verify" workflow (service role only)
create or replace function public.fn_wa_smp_verify_gate()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.wa_smp_verify; v_need text[];
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  update public.wa_smp_verify set status = 'failed', finished_at = now(), note = 'Timed out while running' where status = 'running' and claimed_at < now() - interval '90 minutes';
  update public.wa_smp_verify set status = 'failed', finished_at = now(), note = 'Never started' where status = 'pending' and created_at < now() - interval '3 hours';
  if exists (select 1 from public.wa_smp_verify where status = 'running') then return jsonb_build_object('run', false, 'reason', 'another re-check is running'); end if;
  select * into r from public.wa_smp_verify where status = 'pending' order by id limit 1 for update;
  if not found then return jsonb_build_object('run', false, 'reason', 'nothing pending'); end if;
  -- schools that were read in the last 10 minutes are already fresh
  select coalesce(array_agg(e), '{}') into v_need from unnest(r.emis) e
   where coalesce((select max(st.last_synced) from public.portal_sync_state st where st.emis_code = e), '-infinity') < now() - interval '10 minutes';
  if cardinality(v_need) = 0 then
    update public.wa_smp_verify set status = 'done', claimed_at = now(), finished_at = now(), schools_checked = cardinality(emis), note = 'Already fresh' where id = r.id;
    perform public.fn_wa_smp_release_verifying();
    return jsonb_build_object('run', false, 'reason', 'already fresh');
  end if;
  update public.wa_smp_verify set status = 'running', claimed_at = now(), emis = v_need where id = r.id;
  return jsonb_build_object('run', true, 'id', r.id, 'schools', cardinality(v_need));
end $$;

create or replace function public.fn_wa_smp_verify_codes(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  return coalesce((select to_jsonb(emis) from public.wa_smp_verify where id = p_id), '[]'::jsonb);
end $$;

create or replace function public.fn_wa_smp_verify_finish(p_id bigint, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare r public.wa_smp_verify; v_checked int;
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  select * into r from public.wa_smp_verify where id = p_id for update;
  if not found then return; end if;
  select count(*) into v_checked from unnest(r.emis) e
   where exists (select 1 from public.portal_sync_state st where st.emis_code = e and st.last_synced >= r.claimed_at);
  -- the original (not the 10-minute-fresh) list is covered too: schools skipped as already fresh count as checked
  update public.wa_smp_verify set status = case when p_ok then 'done' else 'failed' end, finished_at = now(), schools_checked = v_checked, note = left(p_note, 300) where id = p_id;
  perform public.fn_wa_smp_release_verifying();
end $$;

-- scheduled / manual sends now go through the re-check
create or replace function public.fn_wa_smp_enqueue_due()
returns integer language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi'; v_today date; v_day date; g record;
        v_n int := 0; v_open boolean; v_fresh boolean; v_any boolean; v_since timestamptz;
begin
  perform public.fn_wa_smp_release_verifying();
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
    select exists (select 1 from public.portal_sync_runs where status in ('done', 'partial') and coalesce(shard, '') <> 'verify' and finished_at >= v_since) into v_fresh;
    select exists (select 1 from public.products pr where pr.active and public.fn_wa_collect_is_day(pr.id, v_day)) into v_any;
    if exists (select 1 from public.wa_smp_jobs j where j.group_jid = g.group_jid and j.report_date = v_day) then continue; end if;
    if not v_any then continue; end if;
    if not v_fresh and v_now < v_today::timestamp + g.smp_file_time + interval '3 hours' then continue; end if;
    begin
      if public.fn_wa_smp_start_job(g.group_jid, v_day, false) is not null then v_n := v_n + 1; end if;
    exception when others then
      insert into public.wa_logs(event, error_message) values ('enqueue_error', left('smp file ' || g.group_jid || ': ' || sqlerrm, 500));
    end;
  end loop;
  return v_n;
end $$;

create or replace function public.fn_wa_smp_queue_now(p_group text)
returns text language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_day date; v_id uuid; v_status text;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  select case when coalesce(smp_file_day, 'previous') = 'same' then (now() at time zone 'Asia/Karachi')::date else (now() at time zone 'Asia/Karachi')::date - 1 end into v_day from public.wa_collect_groups where group_jid = p_group;
  if v_day is null then raise exception 'Group not set up'; end if;
  if exists (select 1 from public.wa_smp_jobs where group_jid = p_group and report_date = v_day and status = 'processing') then raise exception 'It is being sent right now'; end if;
  v_id := public.fn_wa_smp_start_job(p_group, v_day, true);
  select status into v_status from public.wa_smp_jobs where id = v_id;
  return case when v_status = 'verifying' then 'The listed schools are being re-checked on the SMP dashboard first; the report is sent when that finishes (usually within 15-30 minutes).'
              else 'Queued - the worker will send it shortly.' end;
end $$;

-- a re-check run must not count as the day's full sync
do $$ declare d text; o text; begin
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = 'fn_portal_gate'; o := d;
  d := replace(d, 'where started_at >= pl.started_at and status in (''done'', ''partial'')', 'where started_at >= pl.started_at and coalesce(shard, '''') <> ''verify'' and status in (''done'', ''partial'')');
  if d <> o then execute d; end if;
end $$;
