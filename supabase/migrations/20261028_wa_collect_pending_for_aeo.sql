-- WhatsApp data collection: pending entries for registered AEOs, quiet group replies, manual entry clears pending.

-- 1) Group reply ONLY when something was rejected (no per-message "saved" acknowledgement).
do $$
declare d text; old_ret text; new_ret text;
begin
  d := pg_get_functiondef('public.fn_wa_collect_ingest(text,text,text,text,text)'::regprocedure);
  old_ret := substring(d from '(return format\(E''Received.*?v_lines\);)');
  if old_ret is null then
    if position('Please edit the message shared above' in d) > 0 then return; end if;
    raise exception 'ingest return statement not found';
  end if;
  new_ret := $r$if v_bad = 0 then return null; end if;
  return E'⚠ Not accepted:' || (select coalesce(string_agg(E'\n' || l, ''), '') from unnest(string_to_array(v_lines, E'\n')) l where l like '✖%')
    || E'\n\nPlease edit the message shared above and send it again in the group in the same format as shared:\nEMIS Code: \nPacks Consumed: ';$r$;
  execute replace(d, old_ret, new_ret);
end $$;

-- 2) Who is a registered collector: active member with a cell number and at least one markaz
create or replace function public.fn_wa_collect_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.wa_collect_members m
                  where m.user_id = auth.uid() and m.active and nullif(trim(m.phone_e164), '') is not null
                    and cardinality(public.fn_wa_collect_markaz_set(m.user_id)) > 0);
$$;

-- 3) Pending entries for the signed-in registered AEO (own markaz schools only). Nobody else gets rows.
drop policy if exists wa_collect_aeo_read_entries on public.wa_collect_entries;
create or replace function public.fn_wa_collect_pending_for_me(p_date date default null)
returns setof public.wa_collect_entries
language sql stable security definer set search_path = public as $$
  select e.* from public.wa_collect_entries e
    join public.schools s on s.id = e.school_id
   where public.fn_wa_collect_is_member() and e.status = 'pending'
     and s.markaz_id = any(public.fn_wa_collect_markaz_set(auth.uid()))
     and (p_date is null or e.consumption_date = p_date)
   order by e.consumption_date, e.emis_code;
$$;

-- 4) Actions: admin, or a registered AEO for schools in their own markaz
create or replace function public.fn_wa_collect_can_act(p_school uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fn_is_admin() or (public.fn_wa_collect_is_member()
         and exists (select 1 from public.schools s where s.id = p_school and s.markaz_id = any(public.fn_wa_collect_markaz_set(auth.uid()))));
$$;

create or replace function public.fn_wa_collect_update_entry(p_entry uuid, p_packs numeric) returns void
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries;
begin
  select * into e from public.wa_collect_entries where id = p_entry;
  if not found then raise exception 'Entry not found'; end if;
  if e.status <> 'pending' then raise exception 'Only pending entries can be edited'; end if;
  if not public.fn_wa_collect_can_act(e.school_id) then raise exception 'Not allowed'; end if;
  if p_packs is null or p_packs < 0 or p_packs <> trunc(p_packs) then raise exception 'Packs must be a whole number (0 or more)'; end if;
  update public.wa_collect_entries set packs = p_packs, updated_at = now() where id = p_entry;
end $$;

create or replace function public.fn_wa_collect_reject(p_entry uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries;
begin
  select * into e from public.wa_collect_entries where id = p_entry;
  if not found or e.status <> 'pending' then raise exception 'Only pending entries can be removed'; end if;
  if not public.fn_wa_collect_can_act(e.school_id) then raise exception 'Not allowed'; end if;
  update public.wa_collect_entries set status = 'rejected', decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_entry;
end $$;

create or replace function public.fn_wa_collect_approve(p_entry uuid) returns text
language plpgsql security definer set search_path = public as $$
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
  update public.wa_collect_entries set status = 'approved', error_text = null, decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_entry;
  return 'OK';
end $$;

-- 5) Entering the consumption by hand removes the pending entry
create or replace function public.fn_wa_collect_clear_pending() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('smp.wa_approving', true), '') = '1' then return new; end if;
  if new.status = 'active' then
    update public.wa_collect_entries set status = 'rejected', error_text = 'Entered manually', decided_by = auth.uid(), decided_at = now(), updated_at = now()
     where status = 'pending' and school_id = new.school_id and product_id = new.product_id and consumption_date = new.consumption_date;
  end if;
  return new;
end $$;
drop trigger if exists trg_wa_collect_clear_pending on public.consumption;
create trigger trg_wa_collect_clear_pending after insert or update on public.consumption
  for each row execute function public.fn_wa_collect_clear_pending();

revoke all on function public.fn_wa_collect_is_member(), public.fn_wa_collect_pending_for_me(date), public.fn_wa_collect_can_act(uuid) from public, anon;
grant execute on function public.fn_wa_collect_is_member(), public.fn_wa_collect_pending_for_me(date) to authenticated;
revoke all on function public.fn_wa_collect_approve(uuid), public.fn_wa_collect_update_entry(uuid, numeric), public.fn_wa_collect_reject(uuid) from public, anon;
grant execute on function public.fn_wa_collect_approve(uuid), public.fn_wa_collect_update_entry(uuid, numeric), public.fn_wa_collect_reject(uuid) to authenticated;
