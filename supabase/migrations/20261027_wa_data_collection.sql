-- WhatsApp DATA COLLECTION (branch feature/wa-data-collection). Purely additive: new wa_collect_* objects only.
-- Nothing in the existing WhatsApp sending system or the consumption tables is changed. Switched OFF by default.

-- ---------- tables ----------
create table if not exists public.wa_collect_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  send_time time not null default '12:00',
  ack_enabled boolean not null default false,       -- short acknowledgement replies in the group
  auto_approve boolean not null default false,      -- false = Admin approves pending entries (recommended at first)
  updated_at timestamptz not null default now()
);
insert into public.wa_collect_settings (id) values (true) on conflict do nothing;

create table if not exists public.wa_collect_groups (
  group_jid text primary key,
  label text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- people allowed to post data (jurisdiction comes from their profile: markaz + extra markaz)
create table if not exists public.wa_collect_members (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  phone_e164 text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (user_id)
);

create table if not exists public.wa_collect_messages (          -- the daily prompt sent to each group
  id uuid primary key default gen_random_uuid(),
  group_jid text not null,
  collect_date date not null,
  product_id uuid not null references public.products(id),
  message_text text not null,
  status text not null default 'queued' check (status in ('queued','processing','sent','failed','cancelled')),
  attempt_count int not null default 0,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (group_jid, collect_date, product_id)
);

create table if not exists public.wa_collect_inbox (             -- every group message seen (dedupe by WhatsApp id)
  wa_msg_id text primary key,
  group_jid text not null,
  sender text,
  body text,
  created_at timestamptz not null default now()
);

create table if not exists public.wa_collect_entries (
  id uuid primary key default gen_random_uuid(),
  group_jid text,
  member_id uuid references public.wa_collect_members(id),
  school_id uuid references public.schools(id),
  emis_code text,
  product_id uuid references public.products(id),
  consumption_date date,
  packs numeric check (packs >= 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected','invalid')),
  error_text text,
  raw_text text,
  wa_msg_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz
);
create unique index if not exists wa_collect_entries_one_pending
  on public.wa_collect_entries (school_id, product_id, consumption_date) where status = 'pending';

-- ---------- helpers ----------
create or replace function public.fn_wa_collect_digits(p text) returns text language sql immutable as $$
  select translate(coalesce(p,''), '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩', '01234567890123456789');
$$;

create or replace function public.fn_wa_collect_markaz_set(p_user uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[markaz_id] || coalesce(extra_markaz_ids, '{}'::uuid[]), null) from public.profiles where id = p_user;
$$;

create or replace function public.fn_wa_collect_is_day(p_product uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when se.status = 'blocked' then false
    when se.status = 'allowed' then true
    else extract(dow from p_date)::int = any(p.schedule_dow) end
  from public.products p
  left join public.schedule_exceptions se on se.product_id = p.id and se.exception_date = p_date
  where p.id = p_product and p.active;
$$;

-- ---------- security ----------
alter table public.wa_collect_settings enable row level security;
alter table public.wa_collect_groups   enable row level security;
alter table public.wa_collect_members  enable row level security;
alter table public.wa_collect_messages enable row level security;
alter table public.wa_collect_inbox    enable row level security;
alter table public.wa_collect_entries  enable row level security;

drop policy if exists wa_collect_admin_all_settings on public.wa_collect_settings;
create policy wa_collect_admin_all_settings on public.wa_collect_settings for all using (public.fn_is_admin()) with check (public.fn_is_admin());
drop policy if exists wa_collect_admin_all_groups on public.wa_collect_groups;
create policy wa_collect_admin_all_groups on public.wa_collect_groups for all using (public.fn_is_admin()) with check (public.fn_is_admin());
drop policy if exists wa_collect_admin_all_members on public.wa_collect_members;
create policy wa_collect_admin_all_members on public.wa_collect_members for all using (public.fn_is_admin()) with check (public.fn_is_admin());
drop policy if exists wa_collect_admin_read_messages on public.wa_collect_messages;
create policy wa_collect_admin_read_messages on public.wa_collect_messages for select using (public.fn_is_admin());
drop policy if exists wa_collect_admin_read_inbox on public.wa_collect_inbox;
create policy wa_collect_admin_read_inbox on public.wa_collect_inbox for select using (public.fn_is_admin());
drop policy if exists wa_collect_admin_read_entries on public.wa_collect_entries;
create policy wa_collect_admin_read_entries on public.wa_collect_entries for select using (public.fn_is_admin());
-- an AEO sees entries of schools in their own markaz(s) (edits go through fn_wa_collect_update_entry)
drop policy if exists wa_collect_aeo_read_entries on public.wa_collect_entries;
create policy wa_collect_aeo_read_entries on public.wa_collect_entries for select using (
  exists (select 1 from public.schools s where s.id = wa_collect_entries.school_id
          and s.markaz_id = any(public.fn_wa_collect_markaz_set(auth.uid()))));

-- ---------- daily prompt: queue ----------
create or replace function public.fn_wa_collect_enqueue_due() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare cs public.wa_collect_settings; ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi';
        v_today date; g record; p record; v_n int := 0; v_open boolean;
begin
  select * into cs from public.wa_collect_settings where id;
  select * into ws from public.wa_settings where id;
  if not cs.enabled or ws.emergency_stop then return 0; end if;
  if v_now::time < cs.send_time then return 0; end if;
  v_today := v_now::date;
  select coalesce(is_open, true) into v_open from public.program_state where id;
  if v_open is false then return 0; end if;
  for g in select * from public.wa_collect_groups where active loop
    for p in select id, product_name from public.products where active and public.fn_wa_collect_is_day(id, v_today) loop
      insert into public.wa_collect_messages (group_jid, collect_date, product_id, message_text)
      values (g.group_jid, v_today, p.id,
        E'*SMP Daily Consumption – Data Collection*\nDate: ' || to_char(v_today, 'FMDay, DD Mon YYYY') ||
        E'\nProduct: *' || p.product_name || E'*\n\nPlease reply with:\nEMIS Code:\nPacks Consumed:')
      on conflict (group_jid, collect_date, product_id) do nothing;
      if found then v_n := v_n + 1; end if;
    end loop;
  end loop;
  return v_n;
end $$;

create or replace function public.fn_wa_collect_claim_next()
returns table(m_id uuid, m_jid text, m_text text, m_min_gap integer, m_max_gap integer)
language plpgsql security definer set search_path = public, pg_temp as $$
declare cs public.wa_collect_settings; ws public.wa_settings; v_now timestamp := now() at time zone 'Asia/Karachi'; q public.wa_collect_messages;
begin
  perform pg_advisory_xact_lock(hashtext('wa_collect_claim'));
  select * into cs from public.wa_collect_settings where id;
  select * into ws from public.wa_settings where id;
  if not cs.enabled or ws.emergency_stop or not ws.enabled then return; end if;
  if v_now::time < cs.send_time or v_now::time > ws.window_end then return; end if;
  update public.wa_collect_messages set status = 'failed', last_error = 'Worker interrupted mid-send; not retried'
   where status = 'processing' and created_at < now() - interval '10 minutes';
  select * into q from public.wa_collect_messages
   where status = 'queued' and collect_date = v_now::date order by created_at limit 1 for update skip locked;
  if not found then return; end if;
  update public.wa_collect_messages set status = 'processing', attempt_count = attempt_count + 1 where id = q.id;
  return query select q.id, q.group_jid, q.message_text, ws.min_gap_seconds, ws.max_gap_seconds;
end $$;

create or replace function public.fn_wa_collect_report_result(p_id uuid, p_ok boolean, p_provider_id text default null, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ok then
    update public.wa_collect_messages set status = 'sent', sent_at = now(), provider_message_id = p_provider_id, last_error = null where id = p_id;
  else
    update public.wa_collect_messages set status = case when attempt_count >= 3 then 'failed' else 'queued' end,
           last_error = left(coalesce(p_error, 'send failed'), 500) where id = p_id;
  end if;
end $$;

-- ---------- reading replies ----------
-- Called by the worker (service role) for every group message. Returns the acknowledgement text (or null = say nothing).
create or replace function public.fn_wa_collect_ingest(p_group_jid text, p_sender text, p_msg_id text, p_text text, p_quoted text default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cs public.wa_collect_settings; v_member public.wa_collect_members; v_mk uuid[]; v_t text; v_q text;
  v_phone text; v_date date; v_prod uuid; v_prod_name text; v_today date := (now() at time zone 'Asia/Karachi')::date;
  m record; sc record; v_inserted int; v_err text; v_lines text := ''; v_ok int := 0; v_bad int := 0;
  v_months text[] := array['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'];
  rx text; v_in boolean; st public.program_state; v_lock date;
  p1 text := 'emis\s*(?:code)?\s*[:=\-]?\s*(\d{8})[^0-9]{0,60}?packs?\s*(?:consumed)?\s*[:=\-]?\s*(\d{1,6})';
  p2 text := '^\s*(\d{8})\s*[-:=,\s]\s*(\d{1,6})\s*$';

  -- local: parse Date and Product from a text
begin
  select * into cs from public.wa_collect_settings where id;
  if not cs.enabled then return null; end if;
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return null; end if;
  insert into public.wa_collect_inbox (wa_msg_id, group_jid, sender, body) values (p_msg_id, p_group_jid, p_sender, left(p_text, 4000))
    on conflict (wa_msg_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then return null; end if;                          -- already processed

  v_phone := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
  select m.* into v_member from public.wa_collect_members m where m.active and right(regexp_replace(m.phone_e164, '\D', '', 'g'), 10) = v_phone;
  if not found then return null; end if;                              -- not an authorised person: ignore silently
  v_mk := public.fn_wa_collect_markaz_set(v_member.user_id);

  v_t := lower(public.fn_wa_collect_digits(p_text));
  v_q := lower(public.fn_wa_collect_digits(coalesce(p_quoted, '')));
  if not (v_t ~ p1 or v_t ~ ('(?n)' || p2)) then return null; end if;      -- ordinary chatter

  -- date: from the reply, else the replied-to message, else the group's latest prompt
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
  if v_date is null or v_prod is null then
    select cm.collect_date, cm.product_id into sc from public.wa_collect_messages cm
     where cm.group_jid = p_group_jid and cm.status = 'sent' order by cm.sent_at desc limit 1;
    if found then v_date := coalesce(v_date, sc.collect_date); v_prod := coalesce(v_prod, sc.product_id); end if;
  end if;
  if v_prod is not null and v_prod_name is null then select product_name into v_prod_name from public.products where id = v_prod; end if;

  select * into st from public.program_state where id;
  for m in
    select a[1] as emis, a[2]::numeric as packs from regexp_matches(v_t, p1, 'g') as r(a)
    union all
    select a[1], a[2]::numeric from regexp_matches(v_t, p2, 'gn') as r(a) where not (v_t ~ p1)
  loop
    v_err := null; sc := null;
    select s.id, s.markaz_id, s.school_name into sc from public.schools s where s.emis_code = m.emis and s.active;
    if sc.id is null then v_err := 'EMIS code not found';
    elsif not (sc.markaz_id = any(v_mk)) then v_err := 'school is not in your markaz';
    elsif v_date is null or v_prod is null then v_err := 'date/product not identified - reply to the daily message';
    elsif v_date > v_today then v_err := 'date is in the future';
    elsif not coalesce(public.fn_wa_collect_is_day(v_prod, v_date), false) then v_err := v_prod_name || ' is not a consumption day on ' || to_char(v_date, 'DD Mon');
    elsif st.id is not null and (not st.is_open or v_date < st.start_date) then v_err := 'program closed or before start date';
    elsif public.fn_period_locked(v_prod, 'consumption', v_date) is not null then v_err := 'period is locked by Admin';
    elsif exists (select 1 from public.consumption c where c.school_id = sc.id and c.product_id = v_prod and c.consumption_date = v_date and c.status = 'active')
      then v_err := 'already recorded in the system';
    end if;

    if v_err is null then
      insert into public.wa_collect_entries (group_jid, member_id, school_id, emis_code, product_id, consumption_date, packs, status, raw_text, wa_msg_id)
      values (p_group_jid, v_member.id, sc.id, m.emis, v_prod, v_date, m.packs, 'pending', left(p_text, 2000), p_msg_id)
      on conflict (school_id, product_id, consumption_date) where status = 'pending'
      do update set packs = excluded.packs, raw_text = excluded.raw_text, wa_msg_id = excluded.wa_msg_id, member_id = excluded.member_id, updated_at = now();
      v_ok := v_ok + 1;
      v_lines := v_lines || E'\n✔ ' || m.emis || ' - ' || m.packs::bigint || ' packs (' || sc.school_name || ')';
    else
      insert into public.wa_collect_entries (group_jid, member_id, school_id, emis_code, product_id, consumption_date, packs, status, error_text, raw_text, wa_msg_id)
      values (p_group_jid, v_member.id, sc.id, m.emis, v_prod, v_date, m.packs, 'invalid', v_err, left(p_text, 2000), p_msg_id);
      v_bad := v_bad + 1;
      v_lines := v_lines || E'\n✖ ' || m.emis || ' - ' || v_err;
    end if;
  end loop;

  return format(E'Received %s entr%s%s for %s%s%s', v_ok + v_bad, case when v_ok + v_bad = 1 then 'y' else 'ies' end,
                case when v_bad > 0 then ' (' || v_bad || ' not accepted)' else ' (saved as pending)' end,
                coalesce(v_prod_name, 'product'), coalesce(' ' || to_char(v_date, 'DD Mon'), ''), v_lines);
end $$;

-- ---------- AEO / Admin actions ----------
create or replace function public.fn_wa_collect_update_entry(p_entry uuid, p_packs numeric) returns void
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries; v_sm uuid;
begin
  select * into e from public.wa_collect_entries where id = p_entry;
  if not found then raise exception 'Entry not found'; end if;
  if e.status <> 'pending' then raise exception 'Only pending entries can be edited'; end if;
  select markaz_id into v_sm from public.schools where id = e.school_id;
  if not (public.fn_is_admin() or v_sm = any(public.fn_wa_collect_markaz_set(auth.uid()))) then raise exception 'Not allowed'; end if;
  if p_packs is null or p_packs < 0 or p_packs <> trunc(p_packs) then raise exception 'Packs must be a whole number (0 or more)'; end if;
  update public.wa_collect_entries set packs = p_packs, updated_at = now() where id = p_entry;
end $$;

create or replace function public.fn_wa_collect_reject(p_entry uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries; v_sm uuid;
begin
  select * into e from public.wa_collect_entries where id = p_entry;
  if not found or e.status <> 'pending' then raise exception 'Only pending entries can be removed'; end if;
  select markaz_id into v_sm from public.schools where id = e.school_id;
  if not (public.fn_is_admin() or v_sm = any(public.fn_wa_collect_markaz_set(auth.uid()))) then raise exception 'Not allowed'; end if;
  update public.wa_collect_entries set status = 'rejected', decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_entry;
end $$;

-- Admin approval writes the real consumption through the normal rules (schedule, stock, locks, program state).
create or replace function public.fn_wa_collect_approve(p_entry uuid) returns text
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries; v_who text;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  select * into e from public.wa_collect_entries where id = p_entry for update;
  if not found or e.status <> 'pending' then return 'Not pending'; end if;
  select coalesce(p.full_name, '') into v_who from public.wa_collect_members m join public.profiles p on p.id = m.user_id where m.id = e.member_id;
  begin
    perform public.fn_upsert_consumption(e.school_id, e.product_id, e.consumption_date, e.packs, null, 'Via WhatsApp collection' || coalesce(' (' || nullif(v_who, '') || ')', ''), false);
  exception when others then
    update public.wa_collect_entries set error_text = left(sqlerrm, 300), updated_at = now() where id = p_entry;
    return 'Could not approve: ' || sqlerrm;
  end;
  update public.wa_collect_entries set status = 'approved', error_text = null, decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_entry;
  return 'OK';
end $$;

-- ---------- permissions ----------
revoke all on function public.fn_wa_collect_enqueue_due(), public.fn_wa_collect_claim_next(),
  public.fn_wa_collect_report_result(uuid, boolean, text, text), public.fn_wa_collect_ingest(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.fn_wa_collect_enqueue_due(), public.fn_wa_collect_claim_next(),
  public.fn_wa_collect_report_result(uuid, boolean, text, text), public.fn_wa_collect_ingest(text, text, text, text, text) to service_role;
grant execute on function public.fn_wa_collect_update_entry(uuid, numeric), public.fn_wa_collect_reject(uuid), public.fn_wa_collect_approve(uuid) to authenticated;

-- ---------- schedule: the daily prompt is queued by the existing 15-minute rhythm, in its own job ----------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('wa-collect-enqueue-due') where exists (select 1 from cron.job where jobname = 'wa-collect-enqueue-due');
    perform cron.schedule('wa-collect-enqueue-due', '*/15 * * * *', 'select public.fn_wa_collect_enqueue_due()');
  end if;
end $$;
