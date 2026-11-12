-- School list for the portal sync comes from Supabase: tehsil/wing in portal_sync_settings (default KAROR LALISAN / M-EE).
create table if not exists public.portal_sync_settings (
  id boolean primary key default true check (id),
  tehsil text default 'KAROR LALISAN',
  wing text default 'M-EE',
  updated_at timestamptz not null default now()
);
insert into public.portal_sync_settings(id) values (true) on conflict do nothing;
alter table public.portal_sync_settings enable row level security;
drop policy if exists portal_settings_admin on public.portal_sync_settings;
create policy portal_settings_admin on public.portal_sync_settings for all to authenticated
  using (public.fn_is_admin()) with check (public.fn_is_admin());
grant select, update on public.portal_sync_settings to authenticated;

create or replace function public.fn_portal_scope()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare st public.portal_sync_settings;
begin
  if coalesce(auth.role(), current_user) not in ('service_role', 'postgres') then raise exception 'service role only'; end if;
  select * into st from public.portal_sync_settings limit 1;
  return coalesce((select jsonb_agg(s.emis_code order by s.emis_code)
    from public.schools s join public.markaz m on m.id = s.markaz_id
   where s.active and s.emis_code ~ '^\d{8}$'
     and (st.tehsil is null or m.tehsil = st.tehsil) and (st.wing is null or s.wing = st.wing)), '[]'::jsonb);
end $$;
revoke all on function public.fn_portal_scope() from public, anon, authenticated;
grant execute on function public.fn_portal_scope() to service_role;
