-- WhatsApp data collection: an active AEO / admin whose profile has a cell number and a markaz is authorised AUTOMATICALLY
-- (for the schools of their own markaz / extra markaz). No separate "authorised AEO" registration is needed any more.
-- The wa_collect_members table stays only as an optional override (different WhatsApp number) or to PAUSE someone.
-- Run AFTER 20261031. Safe to run more than once.

alter table public.wa_collect_entries add column if not exists sender_user_id uuid references public.profiles(id) on delete set null;

create or replace function public.fn_wa_collect_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p
                  where p.id = auth.uid() and p.active and p.role in ('aeo', 'admin')
                    and length(regexp_replace(coalesce(p.cell_no, ''), '\D', '', 'g')) >= 10
                    and cardinality(public.fn_wa_collect_markaz_set(p.id)) > 0)
     and not exists (select 1 from public.wa_collect_members m where m.user_id = auth.uid() and not m.active);
$$;

-- approval note: also name auto-authorised senders
do $$
declare d text;
begin
  d := pg_get_functiondef('public.fn_wa_collect_approve(uuid)'::regprocedure);
  if position('e.sender_user_id' in d) > 0 then return; end if;
  if position('where m.id = e.member_id),' in d) = 0 then raise exception 'approve text not as expected'; end if;
  execute replace(d, 'where m.id = e.member_id),', 'where m.id = e.member_id), (select p2.full_name from public.profiles p2 where p2.id = e.sender_user_id),');
end $$;
