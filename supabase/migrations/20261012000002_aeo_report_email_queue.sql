-- AEO consumption-report emails: queue + fail-safe trigger.
-- Every saved consumption entry queues (school, date). The send-aeo-report edge function
-- batches waiting rows per markaz and emails that markaz's AEO(s) via Brevo.

create table if not exists public.aeo_report_queue (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  report_date date not null,
  status text not null default 'pending'
    check (status in ('pending','processing','sent','no_recipient','expired','error')),
  attempts int not null default 0,
  last_error text,
  last_changed_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  sent_to text[],
  created_at timestamptz not null default now()
);
-- one waiting row per school+date: repeated edits merge instead of piling up
create unique index if not exists aeo_report_queue_pending_uq
  on public.aeo_report_queue (school_id, report_date) where status = 'pending';
create index if not exists aeo_report_queue_status_idx
  on public.aeo_report_queue (status, last_changed_at);
alter table public.aeo_report_queue enable row level security;
revoke all on public.aeo_report_queue from anon, authenticated;

-- Fail-safe: any error here is swallowed, so saving consumption can never be blocked by email logic.
create or replace function public.trg_queue_aeo_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'active' then
    insert into public.aeo_report_queue (school_id, report_date, last_changed_at)
    values (new.school_id, new.consumption_date, now())
    on conflict (school_id, report_date) where status = 'pending'
    do update set last_changed_at = now();
  end if;
  return null;
exception when others then
  return null;
end;
$$;

drop trigger if exists trg_queue_aeo_report on public.consumption;
create trigger trg_queue_aeo_report
  after insert or update of quantity, status on public.consumption
  for each row execute function public.trg_queue_aeo_report();
