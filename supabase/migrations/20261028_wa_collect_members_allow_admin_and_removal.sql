-- Authorised posters: allow removal, and allow active Admin accounts as well as AEOs (record of the change applied live).
create or replace function public.fn_wa_collect_members_guard() returns trigger language plpgsql security definer set search_path to 'public', 'pg_temp' as $function$
begin
  if tg_op = 'DELETE' then
    return old;
  elsif tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception 'The account of an added member cannot be changed.' using errcode = '42501';
    end if;
  elsif tg_op = 'INSERT' then
    if not exists (select 1 from public.profiles p where p.id = new.user_id and p.role in ('aeo','admin') and p.active) then
      raise exception 'Only an active AEO or Admin account can be added.' using errcode = '23514';
    end if;
  end if;
  return new;
end $function$;
