-- 1) Tolerant collector: every logged teacher message is classified so the format study report
--    shows which variants of the template teachers really send (header removed, "Please reply with"
--    removed, bare "EMIS - packs", free text...).
-- 2) Pre-send check: before a "missing list" is built for a group, today's raw messages of that group
--    are re-checked; anything that arrived but was not turned into an entry (sender registered later,
--    worker had trouble) is ingested first, so the list never names a school that already reported.

alter table public.wa_collect_issues
  add column if not exists format_variant text,
  add column if not exists fields_found   jsonb,
  add column if not exists confidence     text,
  add column if not exists parser_version text;

create or replace function public.fn_wa_collect_classify(p_text text)
returns jsonb language plpgsql immutable set search_path to 'public' as $$
declare t text := lower(public.fn_wa_collect_digits(coalesce(p_text, '')));
        h boolean; ins boolean; d boolean; pr boolean; el boolean; pl boolean; e8 boolean; pk boolean; v text; c text;
begin
  h   := t ~ 'smp\s*daily\s*consumption';
  ins := t ~ 'please\s*reply';
  d   := t ~ 'date\s*:';
  pr  := t ~ 'product\s*:';
  el  := t ~ 'emis';
  pl  := t ~ 'packs?';
  e8  := t ~ '\m\d{8}\M';
  pk  := t ~ '(packs?\s*(consumed)?\s*[:=\-]?\s*\d{1,6})|(^\s*\d{8}\s*[-:=,\s]\s*\d{1,6}\s*$)';
  v := case
    when h and ins          then 'full_template'
    when h                  then 'no_instruction_line'
    when d and pr           then 'no_header'
    when el and pl          then 'labels_only'
    when t ~ '(?n)^\s*\d{8}\s*[-:=,\s]\s*\d{1,6}\s*$' then 'bare_pair'
    else 'free_text' end;
  c := case when e8 and pk and d and pr then 'high' when e8 and pk then 'medium' else 'low' end;
  return jsonb_build_object('variant', v, 'confidence', c,
    'fields', jsonb_build_object('date', d, 'product', pr, 'emis_8_digits', e8, 'packs', pk,
                                 'header', h, 'instruction_line', ins));
end $$;

create or replace function public.fn_wa_collect_classify_trg() returns trigger
language plpgsql set search_path to 'public' as $$
declare j jsonb;
begin
  if new.raw_text is not null then
    j := public.fn_wa_collect_classify(new.raw_text);
    new.format_variant := j->>'variant'; new.confidence := j->>'confidence';
    new.fields_found := j->'fields'; new.parser_version := '2026-11-13';
  end if;
  return new;
end $$;

drop trigger if exists trg_wa_collect_classify on public.wa_collect_issues;
create trigger trg_wa_collect_classify before insert on public.wa_collect_issues
  for each row execute function public.fn_wa_collect_classify_trg();

-- back-fill the messages already logged
update public.wa_collect_issues i
   set format_variant = j->>'variant', confidence = j->>'confidence', fields_found = j->'fields', parser_version = '2026-11-13'
  from (select id, public.fn_wa_collect_classify(raw_text) j from public.wa_collect_issues where raw_text is not null and format_variant is null) x
 where x.id = i.id;

create or replace function public.fn_wa_collect_format_study(p_days integer default 30)
returns table (variant text, messages bigint, accepted bigint, rejected bigint, share_pct numeric, top_reason text, last_seen timestamptz)
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  return query
  with base as (
    select coalesce(format_variant, 'unclassified') v, outcome, category, created_at
      from public.wa_collect_issues
     where raw_text is not null and category is distinct from 'message_edited'
       and coalesce(category, '') not like 'diag%' and created_at > now() - make_interval(days => greatest(coalesce(p_days, 30), 1))),
  tot as (select count(*)::numeric n from base)
  select b.v, count(*), count(*) filter (where b.outcome = 'accepted'), count(*) filter (where b.outcome = 'rejected'),
         round(100 * count(*) / greatest((select n from tot), 1), 1),
         (select b2.category from base b2 where b2.v = b.v and b2.category is not null
           group by b2.category order by count(*) desc limit 1),
         max(b.created_at)
    from base b group by b.v order by count(*) desc;
end $$;
grant execute on function public.fn_wa_collect_format_study(integer) to authenticated;

create or replace function public.fn_wa_collect_precheck_group(p_group text, p_date date)
returns integer language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare r record; n integer := 0;
begin
  for r in
    select i.wa_msg_id, i.sender, i.body
      from public.wa_collect_inbox i
     where i.group_jid = p_group
       and (i.created_at at time zone 'Asia/Karachi')::date = p_date
       and not exists (select 1 from public.wa_collect_entries e where e.wa_msg_id = i.wa_msg_id)
       and not exists (select 1 from public.wa_collect_issues s where s.wa_msg_id = i.wa_msg_id and s.category is distinct from 'unregistered_sender')
       and (lower(i.body) ~ 'emis' or i.body ~ '[0-9]{8}')
     order by i.created_at limit 200
  loop
    begin
      delete from public.wa_collect_inbox where wa_msg_id = r.wa_msg_id;
      perform public.fn_wa_collect_ingest(p_group, r.sender, r.wa_msg_id, r.body);   -- any reply text is dropped: nobody is answered late
      n := n + 1;
    exception when others then null;                                                    -- rolls the delete back too
    end;
  end loop;
  return n;
end $$;

-- the missing list now runs the pre-send check first
do $$
declare d text;
begin
  select replace(pg_get_functiondef(p.oid), E'\r', '') into d
    from pg_proc p where p.proname = 'fn_wa_collect_claim_next' and p.pronamespace = 'public'::regnamespace;
  if d like '%fn_wa_collect_precheck_group%' then return; end if;
  if position('v_txt := public.fn_wa_collect_missing_text(q.group_jid' in d) = 0 then
    raise exception 'claim_next text not as expected - pre-send check not patched';
  end if;
  d := replace(d, 'v_txt := public.fn_wa_collect_missing_text(q.group_jid',
                  'perform public.fn_wa_collect_precheck_group(q.group_jid, q.collect_date);' || E'\n      ' || 'v_txt := public.fn_wa_collect_missing_text(q.group_jid');
  execute d;
end $$;
