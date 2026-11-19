-- Directory phase 3: local login support, add school, bulk import, A-I-DB fallback switch.
-- Applied live; recorded here so the repo matches the database.

alter table public.profiles add column if not exists local_login boolean not null default false;

create table if not exists public.directory_settings (key text primary key, value text not null, updated_at timestamptz not null default now());
insert into public.directory_settings(key, value) values ('aidb_login_fallback', 'on') on conflict (key) do nothing;
alter table public.directory_settings enable row level security;
drop policy if exists directory_settings_admin_read on public.directory_settings;
create policy directory_settings_admin_read on public.directory_settings for select to authenticated using ((select public.fn_is_admin()));

create or replace function public.fn_dir_set_aidb_fallback(p_on boolean) returns void language plpgsql security definer set search_path = public as $$
declare o text;
begin
  perform public.fn__dir_admin();
  select value into o from public.directory_settings where key = 'aidb_login_fallback';
  update public.directory_settings set value = case when p_on then 'on' else 'off' end, updated_at = now() where key = 'aidb_login_fallback';
  perform public.fn__dir_log('user', null, 'A-I-DB login fallback', 'setting', jsonb_build_object('value', o), jsonb_build_object('value', case when p_on then 'on' else 'off' end));
end $$;

-- The school list stays frozen (no deletes, EMIS fixed). New schools are allowed ONLY through fn_dir_add_school.
create or replace function public.trg_schools_frozen() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(current_setting('smp.allow_school_insert', true), '') <> 'on' then
      raise exception 'New schools can only be added by an admin from User Management.';
    end if;
  elsif tg_op = 'DELETE' then
    raise exception 'The school list is final and permanent - schools cannot be deleted.';
  elsif tg_op = 'UPDATE' and new.emis_code is distinct from old.emis_code then
    raise exception 'EMIS codes are fixed and cannot be changed.';
  end if;
  return coalesce(new, old);
end $$;

create or replace function public.fn_dir_add_school(p_emis text, p_name text, p_markaz_id uuid, p_wing text, p_type text, p_enrollment integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare r public.schools; e text := nullif(btrim(p_emis), '');
begin
  perform public.fn__dir_admin();
  if e is null or nullif(btrim(p_name), '') is null then raise exception 'EMIS code and school name are required.'; end if;
  if exists (select 1 from public.schools where emis_code = e) then raise exception 'EMIS % already exists.', e; end if;
  if not exists (select 1 from public.markaz where id = p_markaz_id) then raise exception 'Choose a valid markaz.'; end if;
  perform set_config('smp.allow_school_insert', 'on', true);
  insert into public.schools(emis_code, school_name, markaz_id, wing, school_type, enrollment, active, outsourced, managed_in_smp)
  values (e, btrim(p_name), p_markaz_id, nullif(btrim(p_wing), ''), nullif(btrim(p_type), ''), p_enrollment, true, false, true) returning * into r;
  perform set_config('smp.allow_school_insert', 'off', true);
  perform public.fn__dir_log('school', r.id, r.emis_code || ' ' || r.school_name, 'create', null, to_jsonb(r));
  return r.id;
end $$;

-- Bulk import of school rows: [{emis, markaz, wing, active, name, type, enrollment}] - existing schools are updated
-- (only the columns given), unknown EMIS codes are added when p_allow_add and name + markaz are present.
-- p_apply=false is a preview: nothing is written. Returns one result row per input row.
create or replace function public.fn_dir_import_schools(p_rows jsonb, p_apply boolean, p_allow_add boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; res jsonb := '[]'::jsonb; s public.schools; mk uuid; mkn text; emis text; msg text; act text; ok boolean;
begin
  perform public.fn__dir_admin();
  for x in select * from jsonb_array_elements(p_rows) loop
    emis := nullif(btrim(x->>'emis'), ''); mk := null; msg := null; act := null; ok := true;
    mkn := nullif(btrim(x->>'markaz'), '');
    if mkn is not null then select id into mk from public.markaz where upper(regexp_replace(btrim(name), '\s+', ' ', 'g')) = upper(regexp_replace(mkn, '\s+', ' ', 'g')) limit 1;
      if mk is null then ok := false; msg := 'Markaz "' || mkn || '" not found'; end if; end if;
    if emis is null then ok := false; msg := 'EMIS missing'; end if;
    if ok then
      select * into s from public.schools where emis_code = emis;
      if found then
        act := 'update';
        if p_apply then
          update public.schools set markaz_id = coalesce(mk, markaz_id), wing = coalesce(nullif(btrim(x->>'wing'), ''), wing),
            school_name = coalesce(nullif(btrim(x->>'name'), ''), school_name), school_type = coalesce(nullif(btrim(x->>'type'), ''), school_type),
            enrollment = coalesce(nullif(x->>'enrollment', '')::int, enrollment),
            active = case when outsourced then false else coalesce((nullif(x->>'active', ''))::boolean, active) end, managed_in_smp = true
          where id = s.id;
        end if;
      elsif p_allow_add and mk is not null and nullif(btrim(x->>'name'), '') is not null then
        act := 'add';
        if p_apply then perform public.fn_dir_add_school(emis, x->>'name', mk, x->>'wing', x->>'type', nullif(x->>'enrollment', '')::int); end if;
      else ok := false; msg := case when not p_allow_add then 'EMIS not found (adding is switched off)' else 'EMIS not found - give name and markaz to add it' end;
      end if;
    end if;
    res := res || jsonb_build_array(jsonb_build_object('emis', emis, 'ok', ok, 'action', act, 'message', msg));
  end loop;
  if p_apply then perform public.fn__dir_log('school', null, 'Excel import: ' || jsonb_array_length(p_rows) || ' rows', 'import', null, jsonb_build_object('rows', jsonb_array_length(p_rows))); end if;
  return res;
end $$;

-- Bulk import of user rows (existing accounts only): [{cnic, full_name, role, markaz, extra, tehsil, wing, cell, active}]
create or replace function public.fn_dir_import_users(p_rows jsonb, p_apply boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; res jsonb := '[]'::jsonb; p public.profiles; mk uuid; nm text; ex uuid[]; ok boolean; msg text; role_in text; bad text;
begin
  perform public.fn__dir_admin();
  for x in select * from jsonb_array_elements(p_rows) loop
    ok := true; msg := null; mk := null; ex := '{}'; bad := null;
    select * into p from public.profiles where cnic = nullif(btrim(x->>'cnic'), '');
    if not found then ok := false; msg := 'No account with this CNIC - add the user first';
    else
      role_in := coalesce(nullif(btrim(x->>'role'), ''), p.role);
      if role_in not in ('admin','super_admin','tr','aeo','school_user') then ok := false; msg := 'Unknown role ' || role_in; end if;
      nm := nullif(btrim(x->>'markaz'), '');
      if ok and nm is not null then select id into mk from public.markaz where upper(regexp_replace(btrim(name), '\s+', ' ', 'g')) = upper(regexp_replace(nm, '\s+', ' ', 'g')) limit 1; if mk is null then ok := false; msg := 'Markaz "' || nm || '" not found'; end if; end if;
      if ok and nullif(btrim(x->>'extra'), '') is not null then
        select coalesce(array_agg(m.id), '{}') into ex from public.markaz m where upper(regexp_replace(btrim(m.name), '\s+', ' ', 'g')) in (select upper(regexp_replace(btrim(t), '\s+', ' ', 'g')) from unnest(string_to_array(x->>'extra', ',')) t);
        if cardinality(ex) < cardinality(string_to_array(x->>'extra', ',')) then ok := false; msg := 'One of the extra markaz was not found'; end if;
      end if;
      if ok and p_apply then
        update public.profiles set role = role_in, full_name = coalesce(nullif(btrim(x->>'full_name'), ''), full_name),
          markaz_id = case when nm is not null then mk else markaz_id end,
          extra_markaz_ids = case when nullif(btrim(x->>'extra'), '') is not null then array(select e from unnest(ex) e where e is distinct from coalesce(mk, markaz_id)) else extra_markaz_ids end,
          tehsil = coalesce(nullif(btrim(x->>'tehsil'), ''), tehsil), wing_scope = coalesce(nullif(btrim(x->>'wing'), ''), wing_scope),
          cell_no = coalesce(nullif(btrim(x->>'cell'), ''), cell_no), active = coalesce((nullif(x->>'active', ''))::boolean, active),
          managed_in_smp = true, jurisdiction_source = 'smp', jurisdiction_synced_at = now()
        where id = p.id;
        delete from public.profile_extra_markaz where profile_id = p.id;
        insert into public.profile_extra_markaz(profile_id, markaz_id) select p.id, unnest(extra_markaz_ids) from public.profiles where id = p.id;
      end if;
    end if;
    res := res || jsonb_build_array(jsonb_build_object('cnic', x->>'cnic', 'ok', ok, 'action', case when ok then 'update' end, 'message', msg));
  end loop;
  if p_apply then perform public.fn__dir_log('user', null, 'Excel import: ' || jsonb_array_length(p_rows) || ' rows', 'import', null, jsonb_build_object('rows', jsonb_array_length(p_rows))); end if;
  return res;
end $$;

revoke all on function public.fn_dir_set_aidb_fallback(boolean), public.fn_dir_add_school(text,text,uuid,text,text,integer), public.fn_dir_import_schools(jsonb,boolean,boolean), public.fn_dir_import_users(jsonb,boolean) from public, anon;
grant execute on function public.fn_dir_set_aidb_fallback(boolean), public.fn_dir_add_school(text,text,uuid,text,text,integer), public.fn_dir_import_schools(jsonb,boolean,boolean), public.fn_dir_import_users(jsonb,boolean) to authenticated;
