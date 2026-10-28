-- WhatsApp data collection: low-volume sending so the number is not put at risk.
-- Collection messages (daily message, missing list, replies) now COUNT toward the same daily limit as the missing-report
-- messages, and capacity for every active report recipient is always kept in reserve. Auto-replies are tightly throttled.
-- Safe to run more than once.

alter table public.wa_collect_settings
  add column if not exists max_replies_per_day int not null default 8 check (max_replies_per_day between 0 and 30),
  add column if not exists max_reacts_per_day int not null default 15 check (max_reacts_per_day between 0 and 40),
  add column if not exists max_replies_per_sender int not null default 2 check (max_replies_per_sender between 0 and 10);

-- how many more messages collection may send today without touching the capacity needed for the daily reports
create or replace function public.fn_wa_collect_budget_left() returns integer
language sql stable security definer set search_path = public as $$
  with t as (select (now() at time zone 'Asia/Karachi')::date d),
  u as (select count(*) filter (where l.queue_id is not null) rep, count(*) filter (where l.queue_id is null) col
          from public.wa_logs l, t where l.event = 'claim' and not l.dry_run and (l.created_at at time zone 'Asia/Karachi')::date = t.d)
  select (select daily_cap from public.wa_settings where id) - u.rep - u.col
         - greatest(0, (select count(*) from public.wa_recipients where active and consent_status = 'granted') - u.rep)::int
  from u;
$$;

-- Asks permission for ONE collection message; if granted it is counted against today's limit. kind: prompt | missing | reply
create or replace function public.fn_wa_collect_reserve_send(p_kind text, p_group text default null, p_sender text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare cs public.wa_collect_settings; ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi';
        v_s text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10); v_n int;
begin
  perform pg_advisory_xact_lock(hashtext('wa_collect_reserve'));
  select * into cs from public.wa_collect_settings where id;
  select * into ws from public.wa_settings where id;
  if not cs.enabled or ws.emergency_stop or ws.dry_run or not ws.enabled then return false; end if;
  if v_now::time < cs.window_start or v_now::time > cs.window_end then return false; end if;
  if public.fn_wa_collect_budget_left() < 1 then return false; end if;
  if p_kind = 'reply' then
    select count(*) into v_n from public.wa_logs where event = 'claim' and error_message like 'collect:reply|%' and (created_at at time zone 'Asia/Karachi')::date = v_now::date;
    if v_n >= cs.max_replies_per_day then return false; end if;
    select count(*) into v_n from public.wa_logs where event = 'claim' and error_message like 'collect:reply|%|' || v_s and (created_at at time zone 'Asia/Karachi')::date = v_now::date;
    if v_n >= cs.max_replies_per_sender then return false; end if;
    if exists (select 1 from public.wa_logs where event = 'claim' and error_message like 'collect:reply|' || coalesce(p_group, '') || '|%' and created_at > now() - interval '3 minutes') then return false; end if;
  end if;
  if p_kind = 'react' then
    select count(*) into v_n from public.wa_logs where event = 'claim' and error_message like 'collect:react|%' and (created_at at time zone 'Asia/Karachi')::date = v_now::date;
    if v_n >= cs.max_reacts_per_day then return false; end if;
  end if;
  insert into public.wa_logs (event, dry_run, error_message) values ('claim', false, 'collect:' || p_kind || '|' || coalesce(p_group, '') || '|' || v_s);
  return true;
end $$;

-- the daily message / missing list are sent only when the reserve allows it (otherwise they wait and retry, or expire at midnight)
create or replace function public.fn_wa_collect_claim_next()
returns table(m_id uuid, m_jid text, m_text text, m_min_gap integer, m_max_gap integer)
language plpgsql security definer set search_path = public, pg_temp as $$
declare cs public.wa_collect_settings; ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi'; q public.wa_collect_messages; v_txt text;
begin
  perform pg_advisory_xact_lock(hashtext('wa_collect_claim'));
  select * into cs from public.wa_collect_settings where id;
  select * into ws from public.wa_settings where id;
  if not cs.enabled or ws.emergency_stop or ws.dry_run then return; end if;
  if v_now::time < cs.window_start or v_now::time > cs.window_end then return; end if;
  update public.wa_collect_messages set status = 'failed', last_error = 'Worker interrupted mid-send; not retried'
   where status = 'processing' and created_at < now() - interval '10 minutes';
  loop
    select * into q from public.wa_collect_messages
     where status = 'queued' and collect_date = v_now::date order by kind desc, created_at limit 1 for update skip locked;
    if not found then return; end if;
    if q.kind = 'missing' then
      v_txt := public.fn_wa_collect_missing_text(q.group_jid, q.collect_date, q.product_id);
      if v_txt is null then
        update public.wa_collect_messages set status = 'cancelled', last_error = 'Nothing missing at send time' where id = q.id;
        continue;
      end if;
      update public.wa_collect_messages set message_text = v_txt where id = q.id;
      q.message_text := v_txt;
    end if;
    if not public.fn_wa_collect_reserve_send(q.kind, q.group_jid, null) then return; end if;   -- limit / reserve: wait
    update public.wa_collect_messages set status = 'processing', attempt_count = attempt_count + 1 where id = q.id;
    return query select q.id, q.group_jid, q.message_text, ws.min_gap_seconds, ws.max_gap_seconds;
    return;
  end loop;
end $$;

revoke all on function public.fn_wa_collect_budget_left(), public.fn_wa_collect_reserve_send(text, text, text) from public, anon, authenticated;
grant execute on function public.fn_wa_collect_budget_left(), public.fn_wa_collect_reserve_send(text, text, text) to service_role;
