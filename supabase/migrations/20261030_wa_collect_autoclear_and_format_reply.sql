-- WhatsApp data collection: (1) group reply names the sender's cell number and the EMIS code(s) that broke the format,
-- and a registered sender who broke the format without a readable EMIS/packs pair is told too (ordinary chat is still ignored);
-- (2) pending/rejected entries are cleared automatically. Accepted entries still get no reply.

-- 1) reply text + format-error branch (patches the live ingest function in place)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.fn_wa_collect_ingest(text,text,text,text,text)'::regprocedure);
  if position('format not followed by cell' in d) > 0 then return; end if;
  d := replace(d, $a$Not accepted:'$a$,
                  $b$Not accepted - format not followed by cell 0' || v_phone || E' - EMIS code(s):'$b$);
  d := replace(d, $a$if not (v_t ~ p1 or v_t ~ ('(?n)' || p2)) then return null; end if;$a$,
$b$if not (v_t ~ p1 or v_t ~ ('(?n)' || p2)) then
    -- a registered sender who tried to report (an EMIS-like number, or the words emis / packs consumed) but broke the format is told
    if v_t ~ '\m\d{8}\M' or v_t ~ 'emis' or v_t ~ 'packs?\s*consumed' then
      return E'⚠ Not accepted - format not followed by cell 0' || v_phone || E'\n\nPlease edit the message shared above and send it again in the group in the same format as shared:\nEMIS Code: \nPacks Consumed: ';
    end if;
    return null;
  end if;$b$);
  if position('format not followed by cell' in d) = 0 then raise exception 'ingest patch did not apply'; end if;
  execute d;
end $$;

-- 2) resolved entries leave the database straight away
create or replace function public.fn_wa_collect_clear_pending() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('smp.wa_approving', true), '') = '1' then return new; end if;
  if new.status = 'active' then
    delete from public.wa_collect_entries where status = 'pending' and school_id = new.school_id and product_id = new.product_id and consumption_date = new.consumption_date;
  end if;
  return new;
end $$;

create or replace function public.fn_wa_collect_reject(p_entry uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e public.wa_collect_entries;
begin
  select * into e from public.wa_collect_entries where id = p_entry;
  if not found or e.status <> 'pending' then raise exception 'Only pending entries can be removed'; end if;
  if not public.fn_wa_collect_can_act(e.school_id) then raise exception 'Not allowed'; end if;
  delete from public.wa_collect_entries where id = p_entry;
end $$;

-- 3) nightly clean-up: rejected/invalid entries after 1 day, unreviewed pending entries after 3 days,
--    stored message text after 2 days, old duplicate-guard ids and old daily-message rows after 30 days
create or replace function public.fn_wa_collect_cleanup() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.wa_collect_entries where status in ('rejected','invalid','approved') and updated_at < now() - interval '1 day';
  delete from public.wa_collect_entries where status = 'pending' and updated_at < now() - interval '3 days';
  update public.wa_collect_inbox set body = null where body is not null and created_at < now() - interval '2 days';
  delete from public.wa_collect_inbox where created_at < now() - interval '30 days';
  delete from public.wa_collect_messages where created_at < now() - interval '30 days';
end $$;
revoke all on function public.fn_wa_collect_cleanup() from public, anon, authenticated;
grant execute on function public.fn_wa_collect_cleanup() to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('wa-collect-cleanup') where exists (select 1 from cron.job where jobname = 'wa-collect-cleanup');
    perform cron.schedule('wa-collect-cleanup', '0 22 * * *', 'select public.fn_wa_collect_cleanup()');   -- 03:00 Pakistan time
  end if;
end $$;
