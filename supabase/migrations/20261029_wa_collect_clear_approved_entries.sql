-- Auto Data Collection: once a user approves a pending entry (it is recorded as consumption) the entry is removed from
-- wa_collect_entries, so the pending list does not grow. Only data read/extracted from WhatsApp groups is touched
-- (wa_collect_entries and the text of wa_collect_inbox); nothing else is deleted.
-- Traceability stays on the consumption record itself: remarks = 'Via WhatsApp collection (<sender>)'.
-- Applied to production via the Supabase MCP on 2026-10-29. Rollback: restore the previous fn_wa_collect_approve from
-- supabase/migrations/20261028_wa_collect_pending_for_aeo.sql (it marked the entry 'approved' instead of deleting it).
create or replace function public.fn_wa_collect_approve(p_entry uuid) returns text
language plpgsql security definer set search_path to 'public' as $$
declare e public.wa_collect_entries; v_who text;
begin
  select * into e from public.wa_collect_entries where id = p_entry for update;
  if not found or e.status <> 'pending' then return 'Not pending'; end if;
  if not public.fn_wa_collect_can_act(e.school_id) then raise exception 'Not allowed'; end if;
  select coalesce((select p.full_name from public.wa_collect_members m join public.profiles p on p.id = m.user_id where m.id = e.member_id),
                  (select c.contact_name || ' - ' || c.contact_role from public.wa_collect_school_contacts c where c.id = e.contact_id), '') into v_who;
  perform set_config('smp.wa_approving', '1', true);
  begin
    perform public.fn_upsert_consumption(e.school_id, e.product_id, e.consumption_date, e.packs, null, 'Via WhatsApp collection' || coalesce(' (' || nullif(v_who, '') || ')', ''), false);
  exception when others then
    perform set_config('smp.wa_approving', '', true);
    return 'Could not approve: ' || sqlerrm;
  end;
  perform set_config('smp.wa_approving', '', true);
  -- Approved: the consumption record now holds the data. Remove the pending entry from the database.
  delete from public.wa_collect_entries where id = p_entry;
  -- Once none of that message's entries is still pending, drop the stored message text but keep its id
  -- (the id is only the duplicate guard, so the same WhatsApp message can never be processed twice).
  if e.wa_msg_id is not null and not exists (select 1 from public.wa_collect_entries x where x.wa_msg_id = e.wa_msg_id and x.status = 'pending') then
    update public.wa_collect_inbox set body = null where wa_msg_id = e.wa_msg_id;
  end if;
  return 'OK';
end $$;
revoke all on function public.fn_wa_collect_approve(uuid) from public, anon;
grant execute on function public.fn_wa_collect_approve(uuid) to authenticated;

-- One-time clean-up of entries that were already approved before this change.
with gone as (delete from public.wa_collect_entries where status = 'approved' returning wa_msg_id)
update public.wa_collect_inbox i set body = null
 where i.wa_msg_id in (select wa_msg_id from gone where wa_msg_id is not null)
   and not exists (select 1 from public.wa_collect_entries x where x.wa_msg_id = i.wa_msg_id and x.status = 'pending');
