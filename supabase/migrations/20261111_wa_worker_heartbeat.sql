-- WhatsApp worker heartbeat: the worker reports "I am alive / WhatsApp connected" every minute.
-- The Admin page shows Online / Running-but-not-connected / OFFLINE, and a short list of recent outages
-- (an outage is recorded when the worker starts again after being silent for more than 4 minutes).
-- Run in the SQL editor. Safe to run more than once.

create table if not exists public.wa_worker_heartbeat (
  id boolean primary key default true check (id),
  last_seen timestamptz not null default now(),
  connected boolean not null default false,
  started_at timestamptz,
  connected_at timestamptz,
  version text);
create table if not exists public.wa_worker_outages (
  id bigserial primary key,
  down_from timestamptz not null,           -- last time the worker was heard from
  back_at timestamptz not null,             -- when it started again
  minutes integer not null);
alter table public.wa_worker_heartbeat enable row level security;     -- no policies: only the functions below touch these tables
alter table public.wa_worker_outages enable row level security;

create or replace function public.fn_wa_worker_beat(p_connected boolean, p_started boolean default false, p_version text default null) returns void
language plpgsql security definer set search_path = public as $$
declare h public.wa_worker_heartbeat;
begin
  select * into h from public.wa_worker_heartbeat where id;
  if p_started and h.id is not null and now() - h.last_seen > interval '4 minutes' then
    insert into public.wa_worker_outages (down_from, back_at, minutes) values (h.last_seen, now(), greatest(1, round(extract(epoch from now() - h.last_seen) / 60)::int));
    delete from public.wa_worker_outages where id not in (select id from public.wa_worker_outages order by id desc limit 100);
  end if;
  insert into public.wa_worker_heartbeat (id, last_seen, connected, started_at, connected_at, version)
  values (true, now(), p_connected, case when p_started then now() end, case when p_connected then now() end, p_version)
  on conflict (id) do update set
    last_seen = now(), connected = p_connected,
    started_at = case when p_started then now() else public.wa_worker_heartbeat.started_at end,
    connected_at = case when p_connected and not public.wa_worker_heartbeat.connected then now() else public.wa_worker_heartbeat.connected_at end,
    version = coalesce(p_version, public.wa_worker_heartbeat.version);
end $$;

create or replace function public.fn_wa_worker_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare h public.wa_worker_heartbeat;
begin
  if not public.fn_is_admin() then raise exception 'Admin only'; end if;
  select * into h from public.wa_worker_heartbeat where id;
  return jsonb_build_object(
    'seen', h.id is not null,
    'last_seen', h.last_seen, 'seconds_ago', case when h.id is not null then extract(epoch from now() - h.last_seen)::int end,
    'running', h.id is not null and now() - h.last_seen < interval '3 minutes',
    'connected', coalesce(h.connected, false), 'started_at', h.started_at, 'connected_at', h.connected_at, 'version', h.version,
    'outages_30d', (select count(*) from public.wa_worker_outages where back_at > now() - interval '30 days'),
    'down_minutes_30d', (select coalesce(sum(minutes), 0) from public.wa_worker_outages where back_at > now() - interval '30 days'),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('from', down_from, 'back', back_at, 'minutes', minutes) order by id desc), '[]'::jsonb)
                 from (select * from public.wa_worker_outages order by id desc limit 8) o));
end $$;

revoke all on function public.fn_wa_worker_beat(boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.fn_wa_worker_beat(boolean, boolean, text) to service_role;
revoke all on function public.fn_wa_worker_status() from public, anon;
grant execute on function public.fn_wa_worker_status() to authenticated;
