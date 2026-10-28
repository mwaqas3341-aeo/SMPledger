-- WhatsApp data collection: optional AUTO-APPROVE of pending entries at a time set by the Admin.
-- After that time every pending entry (not yet approved/edited/removed by the AEO) is approved into consumption by the system,
-- using the normal consumption rules (schedule, stock, locks). Entries that fail a rule stay pending. Safe to run more than once.
-- Run after 20261102.

alter table public.wa_collect_settings
  add column if not exists auto_approve_enabled boolean not null default false,
  add column if not exists auto_approve_time time not null default '20:00';

create or replace function public.fn_wa_collect_auto_approve() returns integer
language plpgsql security definer set search_path = public as $$
declare cs public.wa_collect_settings; v_now timestamp := now() at time zone 'Asia/Karachi'; e record; v_admin uuid; v_uid uuid; v_res text; v_n int := 0;
begin
  perform pg_advisory_xact_lock(hashtext('wa_collect_auto_approve'));
  select * into cs from public.wa_collect_settings where id;
  if not cs.enabled or not cs.auto_approve_enabled or v_now::time < cs.auto_approve_time then return 0; end if;
  select id into v_admin from public.profiles where role = 'admin' and active order by id limit 1;
  for e in select id, sender_user_id from public.wa_collect_entries
            where status = 'pending' and consumption_date <= v_now::date order by consumption_date, created_at loop
    v_res := null;
    -- first as the AEO who sent it, otherwise (head teacher post, or a rule refusal) as the Admin
    foreach v_uid in array array[e.sender_user_id, v_admin] loop
      continue when v_uid is null;
      perform set_config('request.jwt.claim.sub', v_uid::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
      perform set_config('test.uid', v_uid::text, true);
      v_res := public.fn_wa_collect_approve(e.id);
      exit when v_res = 'OK' or v_res = 'Not pending';
    end loop;
    if v_res = 'OK' then v_n := v_n + 1; end if;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return v_n;
end $$;

revoke all on function public.fn_wa_collect_auto_approve() from public, anon, authenticated;
grant execute on function public.fn_wa_collect_auto_approve() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('wa-collect-auto-approve') where exists (select 1 from cron.job where jobname = 'wa-collect-auto-approve');
    perform cron.schedule('wa-collect-auto-approve', '*/10 * * * *', 'select public.fn_wa_collect_auto_approve()');
  end if;
end $$;
