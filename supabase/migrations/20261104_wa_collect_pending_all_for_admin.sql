-- Consumption menu: the blue "collected from WhatsApp" box now shows
--  * to an AEO: pending entries of ALL their markaz (home markaz + every extra markaz assigned to them)
--  * to an Admin: pending entries of every school (the Admin can approve / edit anywhere)
-- Approve / Edit rights follow the same rule (fn_wa_collect_can_act). Safe to run more than once.
create or replace function public.fn_wa_collect_pending_for_me(p_date date default null)
returns setof public.wa_collect_entries
language sql stable security definer set search_path = public as $$
  select e.* from public.wa_collect_entries e
    join public.schools s on s.id = e.school_id
   where e.status = 'pending'
     and (public.fn_is_admin()
          or (public.fn_wa_collect_is_member() and s.markaz_id = any(public.fn_wa_collect_markaz_set(auth.uid()))))
     and (p_date is null or e.consumption_date = p_date)
   order by e.consumption_date, e.emis_code;
$$;
grant execute on function public.fn_wa_collect_pending_for_me(date) to authenticated;
