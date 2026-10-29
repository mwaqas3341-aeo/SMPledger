-- WhatsApp data collection: when a message is DELETED, the previous message for the same school / product / date counts again.
-- Every time a newer message replaces a still-pending entry, the older version is kept in a small history table (cleared with the
-- other collection data). Deleting the newest message then brings the previous version back as the pending entry; if there is no
-- earlier message the entry is simply gone. Safe to run more than once. Run after 20261106.

create table if not exists public.wa_collect_entry_history (
  id bigserial primary key,
  group_jid text, school_id uuid not null, product_id uuid not null, consumption_date date not null,
  emis_code text, packs numeric not null, kind text not null default 'new', current_packs numeric,
  member_id uuid, sender_user_id uuid, contact_id uuid, raw_text text, wa_msg_id text,
  created_at timestamptz not null default now());
create index if not exists wa_collect_entry_history_key on public.wa_collect_entry_history (school_id, product_id, consumption_date, id);
create index if not exists wa_collect_entry_history_msg on public.wa_collect_entry_history (wa_msg_id);
alter table public.wa_collect_entry_history enable row level security;      -- no policies: only the database functions touch it

-- a pending entry replaced by a different message -> remember the old version
create or replace function public.fn_wa_collect_keep_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'pending' and old.wa_msg_id is not null and old.wa_msg_id is distinct from new.wa_msg_id then
    insert into public.wa_collect_entry_history (group_jid, school_id, product_id, consumption_date, emis_code, packs, kind, current_packs, member_id, sender_user_id, contact_id, raw_text, wa_msg_id)
    values (old.group_jid, old.school_id, old.product_id, old.consumption_date, old.emis_code, old.packs, old.kind, old.current_packs, old.member_id, old.sender_user_id, old.contact_id, old.raw_text, old.wa_msg_id);
  end if;
  return new;
end $$;
drop trigger if exists trg_wa_collect_keep_history on public.wa_collect_entries;
create trigger trg_wa_collect_keep_history before update on public.wa_collect_entries for each row execute function public.fn_wa_collect_keep_history();

-- delete: remove the message's entries, then bring back the previous message's figure for each affected school/date
create or replace function public.fn_wa_collect_retract(p_group_jid text, p_msg_id text, p_sender text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_back int := 0; d record; h public.wa_collect_entry_history; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return 0; end if;
  delete from public.wa_collect_entry_history where wa_msg_id = p_msg_id;          -- an older version of the deleted message must not come back
  for d in delete from public.wa_collect_entries where wa_msg_id = p_msg_id and status in ('pending','invalid')
            returning school_id, product_id, consumption_date, status loop
    v_n := v_n + 1;
    continue when d.status <> 'pending';
    select * into h from public.wa_collect_entry_history
     where school_id = d.school_id and product_id = d.product_id and consumption_date = d.consumption_date order by id desc limit 1;
    if found
       and not exists (select 1 from public.wa_collect_entries x where x.school_id = d.school_id and x.product_id = d.product_id and x.consumption_date = d.consumption_date and x.status = 'pending')
       and not exists (select 1 from public.consumption c where c.school_id = d.school_id and c.product_id = d.product_id and c.consumption_date = d.consumption_date and c.status = 'active' and c.quantity = h.packs) then
      insert into public.wa_collect_entries (group_jid, member_id, sender_user_id, contact_id, school_id, emis_code, product_id, consumption_date, packs, status, raw_text, wa_msg_id, kind, current_packs)
      values (h.group_jid, h.member_id, h.sender_user_id, h.contact_id, h.school_id, h.emis_code, h.product_id, h.consumption_date, h.packs, 'pending', h.raw_text, h.wa_msg_id, h.kind, h.current_packs);
      delete from public.wa_collect_entry_history where id = h.id;
      v_back := v_back + 1;
    end if;
  end loop;
  if exists (select 1 from public.wa_collect_inbox where wa_msg_id = p_msg_id) then
    update public.wa_collect_inbox set body = null where wa_msg_id = p_msg_id;
    perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'deleted', 'message_deleted',
      v_n || ' pending/invalid entr' || case when v_n = 1 then 'y' else 'ies' end || ' removed; ' || v_back || ' earlier message figure(s) restored (entries already approved are not changed)', null, p_msg_id);
  end if;
  return v_n;
end $$;

-- edit: the old text of that message is dropped from history too (the edited text is read as the newest message)
create or replace function public.fn_wa_collect_edit(p_group_jid text, p_orig_msg_id text, p_edit_id text, p_sender text, p_text text, p_quoted text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_n int; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return null; end if;
  delete from public.wa_collect_entry_history where wa_msg_id = p_orig_msg_id;
  delete from public.wa_collect_entries where wa_msg_id = p_orig_msg_id and status in ('pending','invalid');
  get diagnostics v_n = row_count;
  perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'edited', 'message_edited',
    v_n || ' earlier entr' || case when v_n = 1 then 'y' else 'ies' end || ' replaced by the edited text', p_text, p_orig_msg_id);
  return public.fn_wa_collect_ingest(p_group_jid, p_sender, p_edit_id, p_text, p_quoted);
end $$;

-- history is dropped once the value is recorded (by approval or by hand) and with the daily clean-up
create or replace function public.fn_wa_collect_clear_pending() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' then
    delete from public.wa_collect_entry_history where school_id = new.school_id and product_id = new.product_id and consumption_date = new.consumption_date;
  end if;
  if coalesce(current_setting('smp.wa_approving', true), '') = '1' then return new; end if;
  if new.status = 'active' then
    delete from public.wa_collect_entries where status = 'pending' and school_id = new.school_id and product_id = new.product_id and consumption_date = new.consumption_date;
  end if;
  return new;
end $$;

create or replace function public.fn_wa_collect_cleanup() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.wa_collect_entries where status in ('rejected','invalid','approved') and updated_at < now() - interval '1 day';
  delete from public.wa_collect_entries where status = 'pending' and updated_at < now() - interval '3 days';
  delete from public.wa_collect_entry_history where created_at < now() - interval '3 days';
  update public.wa_collect_inbox set body = null where body is not null and created_at < now() - interval '2 days';
  delete from public.wa_collect_inbox where created_at < now() - interval '30 days';
  delete from public.wa_collect_messages where created_at < now() - interval '30 days';
end $$;

revoke all on function public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text), public.fn_wa_collect_cleanup() from public, anon, authenticated;
grant execute on function public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text), public.fn_wa_collect_cleanup() to service_role;
