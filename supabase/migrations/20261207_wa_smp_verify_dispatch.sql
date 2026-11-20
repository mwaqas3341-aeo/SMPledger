-- GitHub only runs the "*/5" schedule of the portal-verify workflow every several hours, so the
-- pre-send SMP re-check was never started in time (requests ended "Never started" and the report
-- went out with the "could not be re-checked" warning). Here Supabase itself starts the workflow
-- the moment a re-check is waiting, using the GitHub API (workflow_dispatch).
--
-- One-time setup by the owner (NOT in chat): create a fine-grained GitHub token limited to the
-- SMPledger repository with "Actions: Read and write", then in the Supabase SQL editor run
--     select vault.create_secret('<the token>', 'github_dispatch_token');
-- Until that secret exists this does nothing and reports behave as before.

create table if not exists public.wa_smp_dispatch_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  verify_id   bigint,
  net_request bigint,
  note        text
);
alter table public.wa_smp_dispatch_log enable row level security;
drop policy if exists wa_smp_dispatch_log_admin_read on public.wa_smp_dispatch_log;
create policy wa_smp_dispatch_log_admin_read on public.wa_smp_dispatch_log for select to authenticated using (public.fn_is_admin());

create or replace function public.fn_wa_smp_dispatch_verify()
returns text language plpgsql security definer set search_path to 'public','extensions','pg_temp' as $$
declare r record; v_token text; v_req bigint; v_recent int;
begin
  select id into r from public.wa_smp_verify
   where status = 'pending' and created_at > now() - interval '3 hours' order by id limit 1;
  if not found then return 'nothing pending'; end if;
  if exists (select 1 from public.wa_smp_verify where status = 'running') then return 'another re-check is running'; end if;
  -- at most one start per 6 minutes, and 4 tries per request
  select count(*) into v_recent from public.wa_smp_dispatch_log where verify_id = r.id and at > now() - interval '6 minutes';
  if v_recent > 0 then return 'started recently'; end if;
  if (select count(*) from public.wa_smp_dispatch_log where verify_id = r.id) >= 4 then return 'gave up after 4 tries'; end if;
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_dispatch_token' limit 1;
  if v_token is null or v_token = '' then
    insert into public.wa_smp_dispatch_log(verify_id, note) values (r.id, 'no github_dispatch_token in vault');
    return 'no token';
  end if;
  select net.http_post(
    url := 'https://api.github.com/repos/mwaqas3341-aeo/SMPledger/actions/workflows/portal-verify.yml/dispatches',
    body := jsonb_build_object('ref', 'main'),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'smp-ledger-supabase', 'Content-Type', 'application/json'),
    timeout_milliseconds := 10000) into v_req;
  insert into public.wa_smp_dispatch_log(verify_id, net_request, note) values (r.id, v_req, 'dispatch sent');
  return 'dispatched';
end $$;
revoke all on function public.fn_wa_smp_dispatch_verify() from public, anon, authenticated;

select cron.unschedule('wa-smp-verify-dispatch') where exists (select 1 from cron.job where jobname = 'wa-smp-verify-dispatch');
select cron.schedule('wa-smp-verify-dispatch', '* * * * *', 'select public.fn_wa_smp_dispatch_verify()');
