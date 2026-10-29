-- WhatsApp data collection: CORRECTION REQUESTS.
-- When a sender posts a DIFFERENT figure for a school/product/date that is already recorded in consumption, the system no longer
-- rejects it. It keeps a pending "correction" (recorded figure + requested figure) for the AEO / Admin to Approve or Reject.
--  * same figure as already recorded -> nothing to do (no entry, no reply)
--  * corrections are NEVER auto-approved; they always wait for a person
--  * no reply is sent to the group (keeps WhatsApp volume low)
-- Run after 20261105. Safe to run more than once.

alter table public.wa_collect_entries
  add column if not exists kind text not null default 'new',
  add column if not exists current_packs numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'wa_collect_entries_kind_chk') then
    alter table public.wa_collect_entries add constraint wa_collect_entries_kind_chk check (kind in ('new', 'correction'));
  end if;
end $$;

do $$
declare d text; n text;
  procedure_sig regprocedure := 'public.fn_wa_collect_ingest(text,text,text,text,text)'::regprocedure;
begin
  d := pg_get_functiondef(procedure_sig);
  if position('v_corr' in d) > 0 then return; end if;
  n := d;
  n := replace(n, 'v_ok int := 0;', 'v_ok int := 0; v_cur numeric; v_corr boolean := false;');
  n := replace(n, 'v_err := null; v_cat := null; sc := null; v_cid := null;', 'v_err := null; v_cat := null; sc := null; v_cid := null; v_corr := false;');
  n := replace(n, 'then v_err := ''already recorded in the system''; v_cat := ''already_recorded'';',
    'then select c.quantity into v_cur from public.consumption c where c.school_id = sc.id and c.product_id = v_prod and c.consumption_date = v_date and c.status = ''active'' limit 1;
      if v_cur = pr.packs then v_err := ''@same''; else v_corr := true; end if;');
  n := replace(n, E'    if v_err is null then\n      insert into public.wa_collect_entries',
    E'    if v_err = ''@same'' then\n      v_ok := v_ok + 1;\n      perform public.fn_wa_collect_log(p_group_jid, v_phone, v_name, v_kind, pr.emis, ''accepted'', ''same_as_recorded'', ''same figure already recorded - nothing to do'', p_text, p_msg_id);\n      continue;\n    end if;\n    if v_err is null then\n      insert into public.wa_collect_entries');
  n := replace(n, 'packs, status, raw_text, wa_msg_id)
      values (p_group_jid, v_member_id, v_user_id, v_cid, sc.id, pr.emis, v_prod, v_date, pr.packs, ''pending'', left(p_text, 2000), p_msg_id)',
    'packs, status, raw_text, wa_msg_id, kind, current_packs)
      values (p_group_jid, v_member_id, v_user_id, v_cid, sc.id, pr.emis, v_prod, v_date, pr.packs, ''pending'', left(p_text, 2000), p_msg_id, case when v_corr then ''correction'' else ''new'' end, case when v_corr then v_cur end)');
  n := replace(n, 'sender_user_id = excluded.sender_user_id, contact_id = excluded.contact_id, updated_at = now();',
    'sender_user_id = excluded.sender_user_id, contact_id = excluded.contact_id, kind = excluded.kind, current_packs = excluded.current_packs, updated_at = now();');
  n := replace(n, '''accepted'', null, null, p_text, p_msg_id);',
    '''accepted'', case when v_corr then ''correction_requested'' end, case when v_corr then ''differs from the recorded figure '' || v_cur end, p_text, p_msg_id);');
  if n = d or position('v_corr then ''correction''' in n) = 0 or position('@same' in n) = 0 or position('correction_requested' in n) = 0 or position('kind = excluded.kind' in n) = 0 then
    raise exception 'ingest text not as expected - correction patch not applied';
  end if;
  execute n;
end $$;

-- corrections never auto-approve
do $$
declare d text;
begin
  d := pg_get_functiondef('public.fn_wa_collect_auto_approve()'::regprocedure);
  if position('kind = ''new''' in d) > 0 then return; end if;
  if position('where status = ''pending'' and consumption_date' in d) = 0 then raise exception 'auto_approve text not as expected'; end if;
  execute replace(d, 'where status = ''pending'' and consumption_date', 'where status = ''pending'' and kind = ''new'' and consumption_date');
end $$;
