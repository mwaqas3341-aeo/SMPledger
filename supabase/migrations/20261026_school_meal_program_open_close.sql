-- School meal program: open/close state, period history, server-side guards, WhatsApp pause, missing-report clamp.
-- Already applied to the live project; kept here as a record.

create table if not exists public.program_state (
  id boolean primary key default true check (id),
  is_open boolean not null default true,
  start_date date not null,
  wa_prev_emergency boolean,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
create table if not exists public.program_periods (
  id uuid primary key default gen_random_uuid(),
  start_date date not null,
  end_date date,
  started_by uuid references public.profiles(id),
  started_at timestamptz not null default now(),
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  check (end_date is null or end_date >= start_date)
);
create unique index if not exists program_periods_one_open on public.program_periods ((end_date is null)) where end_date is null;

insert into public.program_state (id, is_open, start_date) values (true, true, date '2026-09-28') on conflict (id) do nothing;
insert into public.program_periods (start_date) select date '2026-09-28' where not exists (select 1 from public.program_periods);

alter table public.program_state enable row level security;
alter table public.program_periods enable row level security;
drop policy if exists program_state_read on public.program_state;
create policy program_state_read on public.program_state for select to anon, authenticated using (true);
drop policy if exists program_periods_read on public.program_periods;
create policy program_periods_read on public.program_periods for select to authenticated using (true);

create or replace function public.fn_program_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare dcol text; etype text; j jsonb; jo jsonb; jn jsonb; side text; d date; et text;
        st public.program_state; v_last date;
        ign text[] := array['invoice_flag','invoice_flag_note','updated_at'];
begin
  case tg_table_name
    when 'school_receipts'        then dcol := 'receipt_date';    etype := 'inventory';
    when 'aeo_markaz_receipts'    then dcol := 'receipt_date';    etype := 'inventory';
    when 'inventory_adjustments'  then dcol := 'adjustment_date'; etype := 'inventory';
    when 'inventory_loans'        then dcol := 'loan_date';       etype := 'inventory';
    when 'inventory_loan_returns' then dcol := 'return_date';     etype := 'inventory';
    when 'school_transfers'       then dcol := 'transfer_date';   etype := 'inventory';
    when 'consumption'            then dcol := 'consumption_date'; etype := 'consumption';
    when 'inventory_transactions' then dcol := 'txn_date';        etype := null;
    else return case when tg_op = 'DELETE' then old else new end;
  end case;
  if tg_op = 'UPDATE' then
    jo := to_jsonb(old) - ign; jn := to_jsonb(new) - ign;
    if jo = jn then return new; end if;
  end if;
  select * into st from public.program_state where id;
  if not found then return case when tg_op = 'DELETE' then old else new end; end if;
  if not st.is_open then
    raise exception 'The school meal program is closed. Inventory and consumption entries are stopped until the Admin starts it again.'
      using errcode = 'SMPRG', hint = 'program_closed';
  end if;
  select max(end_date) into v_last from public.program_periods where end_date is not null;
  for side in select unnest(case tg_op when 'INSERT' then array['new'] when 'DELETE' then array['old'] else array['old','new'] end) loop
    j := case side when 'new' then to_jsonb(new) else to_jsonb(old) end;
    d := (j->>dcol)::date;
    if d is null then continue; end if;
    et := coalesce(etype, case when j->>'reference_type' = 'consumption' then 'consumption' else 'inventory' end);
    if et = 'consumption' and d < st.start_date then
      raise exception 'Consumption entries are only allowed from the program start date (%). The date % belongs to an earlier or closed period.',
        to_char(st.start_date, 'FMDD FMMonth YYYY'), to_char(d, 'FMDD FMMonth YYYY')
        using errcode = 'SMPRG', hint = 'before_start';
    elsif et = 'inventory' and v_last is not null and d <= v_last then
      raise exception 'Inventory entries must be dated after the previous program was closed (%). The date % cannot be added or changed.',
        to_char(v_last, 'FMDD FMMonth YYYY'), to_char(d, 'FMDD FMMonth YYYY')
        using errcode = 'SMPRG', hint = 'before_prev_close';
    end if;
  end loop;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
revoke execute on function public.fn_program_guard() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['consumption','school_receipts','aeo_markaz_receipts','inventory_adjustments','inventory_loans','inventory_loan_returns','inventory_transactions','school_transfers'] loop
    execute format('drop trigger if exists trg_00b_program_guard on public.%I', t);
    execute format('create trigger trg_00b_program_guard before insert or update or delete on public.%I for each row execute function public.fn_program_guard()', t);
  end loop;
end $$;

create or replace function public.fn_program_close(p_end_date date default null) returns void
language plpgsql security definer set search_path = public as $$
declare st public.program_state; v_end date; v_stop boolean;
begin
  if not public.fn_is_admin() then raise exception 'Not authorized'; end if;
  select * into st from public.program_state where id for update;
  if not st.is_open then raise exception 'The program is already closed'; end if;
  v_end := coalesce(p_end_date, (now() at time zone 'Asia/Karachi')::date);
  if v_end < st.start_date then raise exception 'Close date cannot be before the program start date'; end if;
  update public.program_periods set end_date = v_end, closed_by = auth.uid(), closed_at = now() where end_date is null;
  select emergency_stop into v_stop from public.wa_settings where id;
  update public.program_state set is_open = false, wa_prev_emergency = coalesce(v_stop, false), updated_by = auth.uid(), updated_at = now() where id;
  update public.wa_settings set emergency_stop = true where id;
  update public.wa_queue set status = 'cancelled', last_error = 'School meal program closed', updated_at = now() where status = 'queued';
end $$;

create or replace function public.fn_program_start(p_start_date date) returns void
language plpgsql security definer set search_path = public as $$
declare st public.program_state; v_last date;
begin
  if not public.fn_is_admin() then raise exception 'Not authorized'; end if;
  if p_start_date is null then raise exception 'Consumption start date is required'; end if;
  select * into st from public.program_state where id for update;
  if st.is_open then raise exception 'The program is already running'; end if;
  select max(end_date) into v_last from public.program_periods;
  if v_last is not null and p_start_date <= v_last then
    raise exception 'Start date must be after the previous close date (%)', to_char(v_last, 'FMDD FMMonth YYYY');
  end if;
  insert into public.program_periods (start_date, started_by) values (p_start_date, auth.uid());
  update public.program_state set is_open = true, start_date = p_start_date, updated_by = auth.uid(), updated_at = now() where id;
  if not coalesce(st.wa_prev_emergency, false) then
    update public.wa_settings set emergency_stop = false where id;
  end if;
end $$;
revoke execute on function public.fn_program_close(date) from public, anon;
revoke execute on function public.fn_program_start(date) from public, anon;
grant execute on function public.fn_program_close(date), public.fn_program_start(date) to authenticated;

alter function public.fn_missing_consumption_period(uuid[], date, date) rename to fn_missing_consumption_period_core;
create or replace function public.fn_missing_consumption_period(p_school_ids uuid[], p_from date, p_to date)
returns table(school_id uuid, emis_code text, school_name text, markaz_name text, tehsil text, wing text, product_id uuid, product_name text, missing_date date)
language sql stable as $$
  select c.* from public.program_state st,
    lateral public.fn_missing_consumption_period_core(p_school_ids, greatest(p_from, st.start_date), p_to) c
  where st.is_open;
$$;
grant execute on function public.fn_missing_consumption_period(uuid[], date, date) to anon, authenticated, service_role;
