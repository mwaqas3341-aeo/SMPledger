-- Admin-designed performas: the uploaded template's columns and where each column gets its data.
-- Only the design is stored - never generated performa data. Everyone signed in can read the
-- designs (so they appear in Reports & Demand -> Performas); only admins can create/change them.
create table if not exists public.performa_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  title_text  text,
  total_row   boolean not null default true,
  columns     jsonb not null,
  active      boolean not null default true,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists performa_templates_name_active on public.performa_templates (lower(name)) where active;
alter table public.performa_templates enable row level security;
drop policy if exists performa_templates_read  on public.performa_templates;
drop policy if exists performa_templates_admin_ins on public.performa_templates;
drop policy if exists performa_templates_admin_upd on public.performa_templates;
create policy performa_templates_read on public.performa_templates for select to authenticated using (true);
create policy performa_templates_admin_ins on public.performa_templates for insert to authenticated with check (public.fn_is_admin());
create policy performa_templates_admin_upd on public.performa_templates for update to authenticated using (public.fn_is_admin()) with check (public.fn_is_admin());
