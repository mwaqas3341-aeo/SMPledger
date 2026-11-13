-- A) Daily run gate: one run a day at a random time between 04:00 and 05:15 Pakistan time (so it ends before 07:00).
-- B) Remarks on consumption issues + "update to what the head teacher reported" function (never writes a zero for a missing report).

create table if not exists public.portal_sync_plan (
  run_date date primary key,
  planned_at timestamptz not null,
  started_at timestamptz,
  attempts int not null default 0
);
alter table public.portal_sync_plan enable row level security;
drop policy if exists portal_plan_read on public.portal_sync_plan;
create policy portal_plan_read on public.portal_sync_plan for select to authenticated using (public.fn_is_admin_or_tr());
grant select on public.portal_sync_plan to authenticated;

create or replace function public.fn_portal_gate()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d date := (now() at time zone 'Asia/Karachi')::date; pl public.portal_sync_plan; ok_runs int; go boolean := false;
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  insert into public.portal_sync_plan(run_date, planned_at)
  values (d, ((d::timestamp + interval '4 hours' + (random() * 75) * interval '1 minute') at time zone 'Asia/Karachi'))
  on conflict (run_date) do nothing;
  select * into pl from public.portal_sync_plan where run_date = d for update;
  if now() < pl.planned_at then
    return jsonb_build_object('run', false, 'reason', 'not yet', 'planned_at', pl.planned_at);
  end if;
  if pl.attempts = 0 then
    go := true;
  elsif pl.attempts < 3 and now() - pl.started_at > interval '40 minutes'
        and (now() at time zone 'Asia/Karachi') < (d::timestamp + interval '6 hours') then
    select count(*) into ok_runs from public.portal_sync_runs where started_at >= pl.started_at and status in ('done', 'partial');
    go := ok_runs = 0;      -- nothing at all was stored by the earlier attempt: try again
  end if;
  if go then
    update public.portal_sync_plan set attempts = attempts + 1, started_at = now() where run_date = d;
  end if;
  return jsonb_build_object('run', go, 'planned_at', pl.planned_at, 'attempt', pl.attempts + case when go then 1 else 0 end);
end $$;
revoke all on function public.fn_portal_gate() from public, anon, authenticated;
grant execute on function public.fn_portal_gate() to service_role;

-- when the head-teacher data was last refreshed (any signed-in user; no school data)
create or replace function public.fn_portal_last_sync()
returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select max(finished_at) from public.portal_sync_runs where status in ('done', 'partial');
$$;
revoke all on function public.fn_portal_last_sync() from public, anon;
grant execute on function public.fn_portal_last_sync() to authenticated;

alter table public.consumption_issues
  add column if not exists remark text,
  add column if not exists applied_by uuid,
  add column if not exists applied_at timestamptz;

create or replace function public.fn_consumption_issue_remark() returns trigger language plpgsql as $$
begin
  new.remark := case new.issue
    when 'head_missing' then 'Head teacher needs to update data on SMP app.'
    when 'aeo_missing'  then 'Head teacher reported ' || trim_scale(new.head_qty)::text || ' on SMP; nothing is recorded here. Use "Update from head teacher" to record it.'
    else 'Head teacher reported ' || trim_scale(new.head_qty)::text || ' on SMP, recorded here ' || trim_scale(new.aeo_qty)::text || '. Use "Update from head teacher" to correct it.'
  end;
  return new;
end $$;
drop trigger if exists trg_consumption_issue_remark on public.consumption_issues;
create trigger trg_consumption_issue_remark before insert or update of issue, head_qty, aeo_qty on public.consumption_issues
  for each row execute function public.fn_consumption_issue_remark();
update public.consumption_issues set issue = issue;

-- Records what the head teachers reported for the caller's schools (all schools they may write for).
-- Only issues where the head teacher reported a quantity above zero are applied; "head teacher reported nothing" is never turned into zero.
create or replace function public.fn_apply_head_consumption(p_school_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_old numeric; v_ss int; v_applied int := 0; v_failed jsonb := '[]'::jsonb; v_no_report int := 0;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select count(*) into v_no_report from public.consumption_issues i
   where i.status = 'open' and i.issue = 'head_missing' and public.fn_can_write_school(i.school_id)
     and (p_school_ids is null or i.school_id = any(p_school_ids));
  for r in
    select i.id, i.school_id, i.product_id, i.emis_code, i.cons_date, i.head_qty, i.issue
      from public.consumption_issues i
     where i.status = 'open' and i.issue in ('qty_differs', 'aeo_missing') and coalesce(i.head_qty, 0) > 0
       and public.fn_can_write_school(i.school_id) and (p_school_ids is null or i.school_id = any(p_school_ids))
     order by i.cons_date, i.emis_code
  loop
    begin
      select quantity, students_served into v_old, v_ss from public.consumption
       where school_id = r.school_id and product_id = r.product_id and consumption_date = r.cons_date and status = 'active';
      perform public.fn_upsert_consumption(r.school_id, r.product_id, r.cons_date, r.head_qty, v_ss,
        'Updated from head teacher report on SMP' || case when v_old is null then '' else ' (was ' || trim_scale(v_old)::text || ')' end, false);
      update public.consumption_issues set status = 'resolved', resolved_at = now(), applied_by = auth.uid(), applied_at = now()
       where id = r.id;
      v_applied := v_applied + 1;
    exception when others then
      v_failed := v_failed || jsonb_build_object('emis', r.emis_code, 'date', r.cons_date, 'reason', left(sqlerrm, 160));
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'failed', v_failed, 'head_has_not_reported', v_no_report);
end $$;
revoke all on function public.fn_apply_head_consumption(uuid[]) from public, anon;
grant execute on function public.fn_apply_head_consumption(uuid[]) to authenticated;
