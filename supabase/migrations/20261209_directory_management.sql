-- Directory management inside SMP (phase 1): admin-only functions to manage markaz, schools and user
-- jurisdictions, with a permanent change log. Nothing here changes how users log in or what they can see.
-- Rule kept: the school list is frozen (no new schools, no deletes, no EMIS changes - trg_schools_frozen).

alter table public.profiles add column if not exists managed_in_smp boolean not null default false;
alter table public.schools  add column if not exists managed_in_smp boolean not null default false;
alter table public.markaz   add column if not exists managed_in_smp boolean not null default false;

create table if not exists public.directory_changes (
  id bigserial primary key,
  changed_at timestamptz not null default now(),
  changed_by uuid,
  changed_by_name text,
  entity text not null,            -- 'user' | 'markaz' | 'school'
  entity_id uuid,
  entity_label text,
  action text not null,
  old_value jsonb,
  new_value jsonb
);
create index if not exists directory_changes_at_idx on public.directory_changes (changed_at desc);
alter table public.directory_changes enable row level security;
drop policy if exists directory_changes_admin_read on public.directory_changes;
create policy directory_changes_admin_read on public.directory_changes for select to authenticated using ((select public.fn_is_admin()));

create or replace function public.fn__dir_admin() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(public.fn_is_admin(), false) then raise exception 'Only an admin can manage the directory.'; end if;
end $$;

create or replace function public.fn__dir_log(p_entity text, p_id uuid, p_label text, p_action text, p_old jsonb, p_new jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.directory_changes(changed_by, changed_by_name, entity, entity_id, entity_label, action, old_value, new_value)
  values (auth.uid(), (select full_name from public.profiles where id = auth.uid()), p_entity, p_id, p_label, p_action, p_old, p_new);
end $$;

-- Markaz: add or edit.
create or replace function public.fn_dir_save_markaz(p_id uuid, p_name text, p_tehsil text, p_district text, p_active boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare o jsonb; r public.markaz; nm text := nullif(btrim(p_name), '');
begin
  perform public.fn__dir_admin();
  if nm is null then raise exception 'Markaz name is required.'; end if;
  if exists (select 1 from public.markaz m where upper(btrim(m.name)) = upper(nm) and m.id is distinct from p_id) then
    raise exception 'A markaz called "%" already exists.', nm;
  end if;
  if p_id is null then
    insert into public.markaz(name, tehsil, district, active, managed_in_smp) values (nm, nullif(btrim(p_tehsil),''), nullif(btrim(p_district),''), coalesce(p_active, true), true) returning * into r;
    perform public.fn__dir_log('markaz', r.id, r.name, 'create', null, to_jsonb(r));
  else
    select to_jsonb(m) into o from public.markaz m where m.id = p_id;
    if o is null then raise exception 'Markaz not found.'; end if;
    update public.markaz set name = nm, tehsil = nullif(btrim(p_tehsil),''), district = nullif(btrim(p_district),''), active = coalesce(p_active, active), managed_in_smp = true where id = p_id returning * into r;
    perform public.fn__dir_log('markaz', r.id, r.name, 'update', o, to_jsonb(r));
  end if;
  return r.id;
end $$;

-- School: edit details (EMIS stays fixed, no add/delete - the school list is frozen).
create or replace function public.fn_dir_save_school(p_id uuid, p_markaz_id uuid, p_name text, p_wing text, p_type text, p_active boolean, p_outsourced boolean, p_enrollment integer)
returns void language plpgsql security definer set search_path = public as $$
declare o jsonb; r public.schools;
begin
  perform public.fn__dir_admin();
  select to_jsonb(s) into o from public.schools s where s.id = p_id;
  if o is null then raise exception 'School not found.'; end if;
  if p_markaz_id is null or not exists (select 1 from public.markaz where id = p_markaz_id) then raise exception 'Choose a valid markaz.'; end if;
  if nullif(btrim(p_name),'') is null then raise exception 'School name is required.'; end if;
  update public.schools set markaz_id = p_markaz_id, school_name = btrim(p_name), wing = nullif(btrim(p_wing),''), school_type = nullif(btrim(p_type),''),
    outsourced = coalesce(p_outsourced, outsourced),
    active = case when coalesce(p_outsourced, outsourced) then false else coalesce(p_active, active) end,
    enrollment = coalesce(p_enrollment, enrollment), managed_in_smp = true
  where id = p_id returning * into r;
  perform public.fn__dir_log('school', r.id, r.emis_code || ' ' || r.school_name, 'update', o, to_jsonb(r));
end $$;

-- Move many schools to another markaz in one step.
create or replace function public.fn_dir_move_schools(p_school_ids uuid[], p_markaz_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; mk text; old jsonb;
begin
  perform public.fn__dir_admin();
  select name into mk from public.markaz where id = p_markaz_id;
  if mk is null then raise exception 'Choose a valid markaz.'; end if;
  select jsonb_agg(jsonb_build_object('id', s.id, 'emis', s.emis_code, 'markaz_id', s.markaz_id)) into old from public.schools s where s.id = any(p_school_ids);
  update public.schools set markaz_id = p_markaz_id, managed_in_smp = true where id = any(p_school_ids) and markaz_id is distinct from p_markaz_id;
  get diagnostics n = row_count;
  perform public.fn__dir_log('school', null, n || ' schools -> ' || mk, 'bulk_move', old, jsonb_build_object('markaz_id', p_markaz_id));
  return n;
end $$;

-- User jurisdiction: role, home markaz, extra markaz, tehsil, wing, status, contact.
create or replace function public.fn_dir_save_user(p_id uuid, p_full_name text, p_role text, p_markaz_id uuid, p_extra uuid[], p_tehsil text, p_wing_scope text, p_cell_no text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare o jsonb; r public.profiles; ex uuid[];
begin
  perform public.fn__dir_admin();
  select to_jsonb(p) into o from public.profiles p where p.id = p_id;
  if o is null then raise exception 'User not found.'; end if;
  if p_role not in ('admin','super_admin','tr','aeo','school_user') then raise exception 'Unknown role.'; end if;
  if p_id = auth.uid() and (p_role not in ('admin','super_admin') or coalesce(p_active, true) = false) then
    raise exception 'You cannot remove your own admin access.';
  end if;
  if p_markaz_id is not null and not exists (select 1 from public.markaz where id = p_markaz_id) then raise exception 'Home markaz not found.'; end if;
  select coalesce(array_agg(distinct m.id), '{}') into ex from public.markaz m where m.id = any(coalesce(p_extra, '{}')) and m.id is distinct from p_markaz_id;
  update public.profiles set full_name = coalesce(nullif(btrim(p_full_name),''), full_name), role = p_role, markaz_id = p_markaz_id, extra_markaz_ids = ex,
    tehsil = nullif(btrim(p_tehsil),''), wing_scope = nullif(btrim(p_wing_scope),''), cell_no = nullif(btrim(p_cell_no),''),
    active = coalesce(p_active, active), managed_in_smp = true, jurisdiction_source = 'smp', jurisdiction_synced_at = now()
  where id = p_id returning * into r;
  delete from public.profile_extra_markaz where profile_id = p_id;
  insert into public.profile_extra_markaz(profile_id, markaz_id) select p_id, unnest(ex);
  perform public.fn__dir_log('user', r.id, coalesce(r.full_name, r.cnic), 'update', o, to_jsonb(r));
end $$;

revoke all on function public.fn__dir_admin(), public.fn__dir_log(text,uuid,text,text,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.fn_dir_save_markaz(uuid,text,text,text,boolean), public.fn_dir_save_school(uuid,uuid,text,text,text,boolean,boolean,integer),
  public.fn_dir_move_schools(uuid[],uuid), public.fn_dir_save_user(uuid,text,text,uuid,uuid[],text,text,text,boolean) from public, anon;
grant execute on function public.fn_dir_save_markaz(uuid,text,text,text,boolean), public.fn_dir_save_school(uuid,uuid,text,text,text,boolean,boolean,integer),
  public.fn_dir_move_schools(uuid[],uuid), public.fn_dir_save_user(uuid,text,text,uuid,uuid[],text,text,text,boolean) to authenticated;
