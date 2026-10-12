-- Local user directory: report email + "maintained locally" lock, plus hardening.
-- Additive only: defaults leave every existing user's behaviour unchanged until an admin edits them.

-- 1) New columns
alter table public.profiles add column if not exists report_email text;
alter table public.profiles add column if not exists locked_scope boolean not null default false;
alter table public.profiles drop constraint if exists profiles_report_email_format;
alter table public.profiles add constraint profiles_report_email_format
  check (report_email is null or report_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
comment on column public.profiles.report_email is 'Real inbox for automatic markaz consumption reports (login emails are @smp.local placeholders).';
comment on column public.profiles.locked_scope is 'true = role/markaz/extra markaz/tehsil/wing/name/cell are maintained in SMP by an admin and are never overwritten by A-I-DB login/sync.';

-- 2) Guard on profiles updates
--    a) Signed-in non-admins may change ONLY report_email. Before this, RLS let any user update
--       their own row including role / markaz_id / extra_markaz_ids (privilege escalation).
--    b) Service-role callers (login / sync-me / sync-directory edge functions) cannot overwrite a
--       locked user with A-I-DB data.
create or replace function public.trg_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    -- server-side caller (edge functions use the service role)
    if old.locked_scope and new.jurisdiction_source like 'aidb%' then
      new.role := old.role;
      new.markaz_id := old.markaz_id;
      new.extra_markaz_ids := old.extra_markaz_ids;
      new.wing_scope := old.wing_scope;
      new.tehsil := old.tehsil;
      new.cell_no := old.cell_no;
      new.full_name := old.full_name;
      new.jurisdiction_source := old.jurisdiction_source;
      new.jurisdiction_synced_at := old.jurisdiction_synced_at;
    end if;
    return new;
  end if;

  if public.fn_is_admin() then
    return new;
  end if;

  -- signed-in non-admin: everything except report_email is read-only
  new.id := old.id;
  new.full_name := old.full_name;
  new.role := old.role;
  new.markaz_id := old.markaz_id;
  new.school_id := old.school_id;
  new.active := old.active;
  new.cnic := old.cnic;
  new.tehsil := old.tehsil;
  new.cell_no := old.cell_no;
  new.extra_markaz_ids := old.extra_markaz_ids;
  new.wing_scope := old.wing_scope;
  new.jurisdiction_source := old.jurisdiction_source;
  new.jurisdiction_synced_at := old.jurisdiction_synced_at;
  new.locked_scope := old.locked_scope;
  new.created_at := old.created_at;
  return new;
end;
$$;
drop trigger if exists trg_profiles_guard on public.profiles;
create trigger trg_profiles_guard before update on public.profiles
  for each row execute function public.trg_profiles_guard();

-- 3) Keep profile_extra_markaz (used by fn_aeo_directory) in step with extra_markaz_ids for
--    locally maintained users, and stop the A-I-DB bulk sync rewriting it for them.
create or replace function public.trg_profiles_sync_extra_markaz()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('smp.pem_rebuild', '1', true);
  delete from public.profile_extra_markaz where profile_id = new.id;
  insert into public.profile_extra_markaz (profile_id, markaz_id)
    select new.id, x from unnest(coalesce(new.extra_markaz_ids, '{}'::uuid[])) as x
    where x is distinct from new.markaz_id
    on conflict do nothing;
  perform set_config('smp.pem_rebuild', '0', true);
  return null;
end;
$$;
drop trigger if exists trg_profiles_sync_extra_markaz on public.profiles;
create trigger trg_profiles_sync_extra_markaz after update on public.profiles
  for each row
  when (new.locked_scope and (old.extra_markaz_ids is distinct from new.extra_markaz_ids
        or old.markaz_id is distinct from new.markaz_id
        or old.locked_scope is distinct from new.locked_scope))
  execute function public.trg_profiles_sync_extra_markaz();

create or replace function public.trg_pem_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_pid uuid;
begin
  if coalesce(current_setting('smp.pem_rebuild', true), '0') = '1' then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  v_pid := case when tg_op = 'DELETE' then old.profile_id else new.profile_id end;
  if exists (select 1 from public.profiles where id = v_pid and locked_scope) then
    return null; -- silently skip: this user's assignments are managed locally
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$$;
drop trigger if exists trg_pem_guard on public.profile_extra_markaz;
create trigger trg_pem_guard before insert or delete on public.profile_extra_markaz
  for each row execute function public.trg_pem_guard();
