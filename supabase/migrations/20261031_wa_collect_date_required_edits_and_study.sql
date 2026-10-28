-- WhatsApp data collection: (1) a report must carry its Date (the sender is asked to add it and send again),
-- (2) edited / deleted WhatsApp messages keep the pending list correct, (3) every attempt is logged for a mistake study.
-- Safe to run more than once. Replaces fn_wa_collect_ingest entirely (it also contains the "format not followed by cell" reply).

create table if not exists public.wa_collect_issues (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  group_jid text,
  sender_last10 text,
  sender_name text,
  sender_kind text,                                   -- aeo | contact | unregistered
  emis_code text,
  outcome text not null check (outcome in ('accepted','rejected','ignored','edited','deleted')),
  category text,                                      -- why it was rejected (or what happened)
  detail text,
  raw_text text,
  wa_msg_id text
);
create index if not exists wa_collect_issues_created on public.wa_collect_issues (created_at);
alter table public.wa_collect_issues enable row level security;
drop policy if exists wa_collect_admin_read_issues on public.wa_collect_issues;
create policy wa_collect_admin_read_issues on public.wa_collect_issues for select using (public.fn_is_admin());

create or replace function public.fn_wa_collect_log(p_group text, p_phone text, p_name text, p_kind text, p_emis text,
                                                    p_outcome text, p_cat text, p_detail text, p_raw text, p_msg text) returns void
language sql security definer set search_path = public as $$
  insert into public.wa_collect_issues (group_jid, sender_last10, sender_name, sender_kind, emis_code, outcome, category, detail, raw_text, wa_msg_id)
  values (p_group, p_phone, p_name, p_kind, p_emis, p_outcome, p_cat, p_detail, left(p_raw, 600), p_msg);
$$;

create or replace function public.fn_wa_collect_ingest(p_group_jid text, p_sender text, p_msg_id text, p_text text, p_quoted text default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cs public.wa_collect_settings; v_member public.wa_collect_members; v_member_id uuid; v_mk uuid[]; v_cschools uuid[]; v_contact boolean := false; v_cid uuid;
  v_t text; v_q text; v_phone text; v_name text; v_kind text; v_date date; v_prod uuid; v_prod_name text;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  pr record; sc record; v_inserted int; v_err text; v_cat text; v_lines text := ''; v_ok int := 0; v_bad int := 0; v_n int;
  v_months text[] := array['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'];
  rx text; st public.program_state; v_fd text; v_fp text; v_footer text; v_reportlike boolean; v_parsed boolean;
  p1 text := 'emis\s*(?:code)?\s*[:=\-]?\s*(\d{8})[^0-9]{0,60}?packs?\s*(?:consumed)?\s*[:=\-]?\s*(\d{1,6})';
  p2 text := '^\s*(\d{8})\s*[-:=,\s]\s*(\d{1,6})\s*$';
begin
  select * into cs from public.wa_collect_settings where id;
  if not cs.enabled then return null; end if;
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return null; end if;
  insert into public.wa_collect_inbox (wa_msg_id, group_jid, sender, body) values (p_msg_id, p_group_jid, p_sender, left(p_text, 4000))
    on conflict (wa_msg_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then return null; end if;                          -- already processed

  v_t := lower(public.fn_wa_collect_digits(p_text));
  v_q := lower(public.fn_wa_collect_digits(coalesce(p_quoted, '')));
  v_parsed := v_t ~ p1 or v_t ~ ('(?n)' || p2);
  v_reportlike := v_parsed or v_t ~ '\m\d{8}\M' or v_t ~ 'emis' or v_t ~ 'packs?\s*consumed';

  v_phone := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
  select m.* into v_member from public.wa_collect_members m where m.active and right(regexp_replace(m.phone_e164, '\D', '', 'g'), 10) = v_phone;
  if found then
    v_member_id := v_member.id; v_kind := 'aeo';
    v_mk := public.fn_wa_collect_markaz_set(v_member.user_id);
    select p.full_name into v_name from public.profiles p where p.id = v_member.user_id;
  else
    select array_agg(distinct c.school_id), max(c.contact_name) into v_cschools, v_name from public.wa_collect_school_contacts c
     where c.active and right(regexp_replace(c.phone_e164, '\D', '', 'g'), 10) = v_phone;
    if v_cschools is null then
      if v_reportlike then perform public.fn_wa_collect_log(p_group_jid, v_phone, null, 'unregistered', null, 'ignored', 'unregistered_sender', 'Report-like message from a number that is not registered', p_text, p_msg_id); end if;
      return null;                                                      -- unknown sender: no reply
    end if;
    v_contact := true; v_kind := 'contact'; v_mk := '{}';
  end if;

  -- the format shown to the sender when something is wrong: the latest daily message of this group
  select to_char(cm.collect_date, 'FMDay, DD Mon YYYY'), p.product_name into v_fd, v_fp
    from public.wa_collect_messages cm join public.products p on p.id = cm.product_id
   where cm.group_jid = p_group_jid and cm.kind = 'prompt' and cm.status = 'sent' order by cm.sent_at desc limit 1;
  v_footer := E'\n\nPlease edit the message shared above and send it again in the group in the same format as shared:\n'
              || case when v_fd is not null then 'Date: ' || v_fd || E'\nProduct: ' || v_fp || E'\n' else 'Date: ' || to_char(v_today, 'FMDay, DD Mon YYYY') || E'\n' end
              || E'EMIS Code: \nPacks Consumed: ';

  if not v_parsed then
    if v_reportlike then                                               -- tried to report but broke the format
      perform public.fn_wa_collect_log(p_group_jid, v_phone, v_name, v_kind, null, 'rejected', 'format_unreadable', 'EMIS code / packs not readable', p_text, p_msg_id);
      return E'⚠ Not accepted - format not followed by cell 0' || v_phone || E'\n✖ EMIS code and packs could not be read' || v_footer;
    end if;
    return null;                                                       -- ordinary chat
  end if;

  -- date and product: from the message itself or the message it replies to (no guessing from older prompts)
  for rx in select unnest(array[v_t, v_q]) loop
    exit when v_date is not null;
    declare a text[];
    begin
      a := regexp_match(rx, 'date\s*:[^\n]*?(\d{1,2})\s*([a-z]{3})[a-z]*\.?,?\s*(\d{4})');
      if a is not null and array_position(v_months, a[2]) is not null then
        v_date := make_date(a[3]::int, array_position(v_months, a[2]), a[1]::int);
      else
        a := regexp_match(rx, 'date\s*:[^\n]*?(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})');
        if a is not null then v_date := make_date(a[3]::int, a[2]::int, a[1]::int); end if;
      end if;
    exception when others then v_date := null; end;
  end loop;
  for rx in select unnest(array[v_t, v_q]) loop
    exit when v_prod is not null;
    select p.id, p.product_name into v_prod, v_prod_name from public.products p
     where p.active and rx ~ ('product\s*:\s*\*?\s*' || lower(p.product_name)) limit 1;
  end loop;
  if v_prod is null and v_date is not null then                        -- only one product is distributed that day: no need to name it
    select count(*) into v_n from public.products p where p.active and public.fn_wa_collect_is_day(p.id, v_date);
    if v_n = 1 then select p.id, p.product_name into v_prod, v_prod_name from public.products p where p.active and public.fn_wa_collect_is_day(p.id, v_date) limit 1; end if;
  end if;

  select * into st from public.program_state where id;
  for pr in
    select a[1] as emis, a[2]::numeric as packs from regexp_matches(v_t, p1, 'g') as r(a)
    union all
    select a[1], a[2]::numeric from regexp_matches(v_t, p2, 'gn') as r(a) where not (v_t ~ p1)
  loop
    v_err := null; v_cat := null; sc := null; v_cid := null;
    select s.id, s.markaz_id, s.school_name into sc from public.schools s where s.emis_code = pr.emis and s.active;
    if sc.id is null then v_err := 'EMIS code not found'; v_cat := 'emis_not_found';
    elsif v_contact and not (sc.id = any(v_cschools)) then v_err := 'your number is not registered for this school'; v_cat := 'not_registered_for_school';
    elsif not v_contact and not (sc.markaz_id = any(v_mk)) then v_err := 'school is not in your markaz'; v_cat := 'wrong_markaz';
    elsif not coalesce(public.fn_wa_collect_in_scope(p_group_jid, sc.markaz_id), false) then v_err := 'school is not in this group''s jurisdiction'; v_cat := 'outside_group_jurisdiction';
    elsif v_date is null then v_err := 'date missing - add the Date line in the same message'; v_cat := 'date_missing';
    elsif v_prod is null then v_err := 'product missing - add the Product line in the same message'; v_cat := 'product_missing';
    elsif v_date > v_today then v_err := 'date is in the future'; v_cat := 'future_date';
    elsif not coalesce(public.fn_wa_collect_is_day(v_prod, v_date), false) then v_err := v_prod_name || ' is not a consumption day on ' || to_char(v_date, 'DD Mon'); v_cat := 'not_consumption_day';
    elsif st.id is not null and (not st.is_open or v_date < st.start_date) then v_err := 'program closed or before start date'; v_cat := 'program_closed';
    elsif public.fn_period_locked(v_prod, 'consumption', v_date) is not null then v_err := 'period is locked by Admin'; v_cat := 'period_locked';
    elsif exists (select 1 from public.consumption c where c.school_id = sc.id and c.product_id = v_prod and c.consumption_date = v_date and c.status = 'active')
      then v_err := 'already recorded in the system'; v_cat := 'already_recorded';
    end if;

    if v_contact and sc.id is not null then
      select c.id into v_cid from public.wa_collect_school_contacts c
       where c.active and c.school_id = sc.id and right(regexp_replace(c.phone_e164, '\D', '', 'g'), 10) = v_phone limit 1;
    end if;
    if v_err is null then
      insert into public.wa_collect_entries (group_jid, member_id, contact_id, school_id, emis_code, product_id, consumption_date, packs, status, raw_text, wa_msg_id)
      values (p_group_jid, v_member_id, v_cid, sc.id, pr.emis, v_prod, v_date, pr.packs, 'pending', left(p_text, 2000), p_msg_id)
      on conflict (school_id, product_id, consumption_date) where status = 'pending'
      do update set packs = excluded.packs, raw_text = excluded.raw_text, wa_msg_id = excluded.wa_msg_id, member_id = excluded.member_id, contact_id = excluded.contact_id, updated_at = now();
      v_ok := v_ok + 1;
      perform public.fn_wa_collect_log(p_group_jid, v_phone, v_name, v_kind, pr.emis, 'accepted', null, null, p_text, p_msg_id);
    else
      insert into public.wa_collect_entries (group_jid, member_id, contact_id, school_id, emis_code, product_id, consumption_date, packs, status, error_text, raw_text, wa_msg_id)
      values (p_group_jid, v_member_id, v_cid, sc.id, pr.emis, v_prod, v_date, pr.packs, 'invalid', v_err, left(p_text, 2000), p_msg_id);
      v_bad := v_bad + 1;
      v_lines := v_lines || E'\n✖ ' || pr.emis || ' - ' || v_err;
      perform public.fn_wa_collect_log(p_group_jid, v_phone, v_name, v_kind, pr.emis, 'rejected', v_cat, v_err, p_text, p_msg_id);
    end if;
  end loop;

  -- saved entries are not acknowledged; only rejected ones get a reply naming the cell number and the EMIS code(s)
  if v_bad = 0 then return null; end if;
  return E'⚠ Not accepted - format not followed by cell 0' || v_phone || ' - EMIS code(s):' || v_lines || v_footer;
end $$;

-- A WhatsApp message was deleted by its sender: its still-pending entries are removed.
create or replace function public.fn_wa_collect_retract(p_group_jid text, p_msg_id text, p_sender text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare v_n int; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return 0; end if;
  delete from public.wa_collect_entries where wa_msg_id = p_msg_id and status in ('pending','invalid');
  get diagnostics v_n = row_count;
  if exists (select 1 from public.wa_collect_inbox where wa_msg_id = p_msg_id) then
    update public.wa_collect_inbox set body = null where wa_msg_id = p_msg_id;
    perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'deleted', 'message_deleted',
      v_n || ' pending/invalid entr' || case when v_n = 1 then 'y' else 'ies' end || ' removed (entries already approved are not changed)', null, p_msg_id);
  end if;
  return v_n;
end $$;

-- A WhatsApp message was edited: entries made from the old text are dropped and the new text is read as a fresh report.
create or replace function public.fn_wa_collect_edit(p_group_jid text, p_orig_msg_id text, p_edit_id text, p_sender text, p_text text, p_quoted text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_n int; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return null; end if;
  if not exists (select 1 from public.wa_collect_inbox where wa_msg_id = p_orig_msg_id) then return null; end if;   -- not a message we read
  delete from public.wa_collect_entries where wa_msg_id = p_orig_msg_id and status in ('pending','invalid');
  get diagnostics v_n = row_count;
  perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'edited', 'message_edited',
    v_n || ' earlier entr' || case when v_n = 1 then 'y' else 'ies' end || ' replaced by the edited text', p_text, p_orig_msg_id);
  return public.fn_wa_collect_ingest(p_group_jid, p_sender, p_edit_id, p_text, p_quoted);
end $$;

-- Mistake study (Admin only): everything since the log began, or the last N days
create or replace function public.fn_wa_collect_issue_summary(p_days integer default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_from timestamptz; r jsonb;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  v_from := case when p_days is null then '-infinity'::timestamptz else now() - make_interval(days => p_days) end;
  select jsonb_build_object(
    'first_logged', (select min(created_at) from public.wa_collect_issues),
    'days_logged', coalesce((select count(distinct (created_at at time zone 'Asia/Karachi')::date) from public.wa_collect_issues), 0),
    'accepted', (select count(*) from public.wa_collect_issues where outcome = 'accepted' and created_at >= v_from),
    'rejected', (select count(*) from public.wa_collect_issues where outcome = 'rejected' and created_at >= v_from),
    'ignored',  (select count(*) from public.wa_collect_issues where outcome = 'ignored' and created_at >= v_from),
    'edited',   (select count(*) from public.wa_collect_issues where outcome = 'edited' and created_at >= v_from),
    'deleted',  (select count(*) from public.wa_collect_issues where outcome = 'deleted' and created_at >= v_from),
    'by_category', coalesce((select jsonb_agg(x order by (x->>'n')::int desc) from (
        select jsonb_build_object('category', category, 'n', count(*), 'senders', count(distinct sender_last10)) x
        from public.wa_collect_issues where outcome in ('rejected','ignored') and created_at >= v_from group by category) q), '[]'),
    'by_sender', coalesce((select jsonb_agg(x order by (x->>'rejected')::int desc) from (
        select jsonb_build_object('name', coalesce(max(sender_name), ''), 'phone', '0' || sender_last10, 'kind', max(sender_kind),
               'accepted', count(*) filter (where outcome = 'accepted'), 'rejected', count(*) filter (where outcome = 'rejected'),
               'main_mistake', (select category from public.wa_collect_issues i2 where i2.sender_last10 = i.sender_last10 and i2.outcome = 'rejected' and i2.created_at >= v_from group by category order by count(*) desc limit 1)) x
        from public.wa_collect_issues i where created_at >= v_from and sender_last10 is not null and outcome in ('accepted','rejected') group by sender_last10) q), '[]'),
    'by_day', coalesce((select jsonb_agg(x order by x->>'day') from (
        select jsonb_build_object('day', (created_at at time zone 'Asia/Karachi')::date, 'accepted', count(*) filter (where outcome = 'accepted'), 'rejected', count(*) filter (where outcome = 'rejected')) x
        from public.wa_collect_issues where created_at >= v_from and outcome in ('accepted','rejected') group by (created_at at time zone 'Asia/Karachi')::date) q), '[]'),
    'recent', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
        select jsonb_build_object('at', created_at, 'sender', coalesce(sender_name, '') || ' 0' || coalesce(sender_last10, ''), 'emis', emis_code, 'category', category, 'detail', detail, 'text', raw_text) x
        from public.wa_collect_issues where outcome in ('rejected','ignored') and created_at >= v_from order by created_at desc limit 40) q), '[]')
  ) into r;
  return r;
end $$;

revoke all on function public.fn_wa_collect_log(text,text,text,text,text,text,text,text,text,text), public.fn_wa_collect_ingest(text,text,text,text,text),
  public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.fn_wa_collect_log(text,text,text,text,text,text,text,text,text,text), public.fn_wa_collect_ingest(text,text,text,text,text),
  public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text) to service_role;
revoke all on function public.fn_wa_collect_issue_summary(integer) from public, anon;
grant execute on function public.fn_wa_collect_issue_summary(integer) to authenticated;
