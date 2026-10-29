-- WhatsApp data collection: an EDITED message keeps working with later edits and deletes.
-- After an edit the entry carries the id "<original id>#e<hash>"; deleting the original message (or editing it again) must find it.
-- Run after 20261107. Safe to run more than once.
-- delete: remove the message's entries, then bring back the previous message's figure for each affected school/date
create or replace function public.fn_wa_collect_retract(p_group_jid text, p_msg_id text, p_sender text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_back int := 0; d record; h public.wa_collect_entry_history; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return 0; end if;
  delete from public.wa_collect_entry_history where wa_msg_id = p_msg_id or wa_msg_id like p_msg_id || '#e%';          -- an older version of the deleted message must not come back
  for d in delete from public.wa_collect_entries where (wa_msg_id = p_msg_id or wa_msg_id like p_msg_id || '#e%') and status in ('pending','invalid')
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
  delete from public.wa_collect_entry_history where wa_msg_id = p_orig_msg_id or wa_msg_id like p_orig_msg_id || '#e%';
  delete from public.wa_collect_entries where (wa_msg_id = p_orig_msg_id or wa_msg_id like p_orig_msg_id || '#e%') and status in ('pending','invalid');
  get diagnostics v_n = row_count;
  perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'edited', 'message_edited',
    v_n || ' earlier entr' || case when v_n = 1 then 'y' else 'ies' end || ' replaced by the edited text', p_text, p_orig_msg_id);
  return public.fn_wa_collect_ingest(p_group_jid, p_sender, p_edit_id, p_text, p_quoted);
end $$;


revoke all on function public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.fn_wa_collect_retract(text,text,text), public.fn_wa_collect_edit(text,text,text,text,text,text) to service_role;
