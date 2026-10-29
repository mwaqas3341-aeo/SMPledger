-- Edited messages: the edited text is always read, even when the system never saw the original
-- (worker was restarting, or the message was sent before data collection started). Earlier pending/invalid entries of the
-- original message are still replaced; approved entries are never changed. Safe to run more than once.
create or replace function public.fn_wa_collect_edit(p_group_jid text, p_orig_msg_id text, p_edit_id text, p_sender text, p_text text, p_quoted text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_n int; v_phone text := right(regexp_replace(coalesce(p_sender, ''), '\D', '', 'g'), 10);
begin
  if not exists (select 1 from public.wa_collect_groups where group_jid = p_group_jid and active) then return null; end if;
  delete from public.wa_collect_entries where wa_msg_id = p_orig_msg_id and status in ('pending','invalid');
  get diagnostics v_n = row_count;
  perform public.fn_wa_collect_log(p_group_jid, v_phone, null, null, null, 'edited', 'message_edited',
    v_n || ' earlier entr' || case when v_n = 1 then 'y' else 'ies' end || ' replaced by the edited text', p_text, p_orig_msg_id);
  return public.fn_wa_collect_ingest(p_group_jid, p_sender, p_edit_id, p_text, p_quoted);
end $$;
revoke all on function public.fn_wa_collect_edit(text,text,text,text,text,text) from public, anon, authenticated;
grant execute on function public.fn_wa_collect_edit(text,text,text,text,text,text) to service_role;
