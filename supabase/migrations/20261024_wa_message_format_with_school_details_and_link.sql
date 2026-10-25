-- WhatsApp missing-consumption message: school-level detail + app link (editable in wa_settings.app_link)
alter table public.wa_settings add column if not exists app_link text not null default 'https://mwaqas3341-aeo.github.io/SMPledger/index.html';

create or replace function public.fn_wa_build(p_tehsil text, p_wing text, p_from date, p_to date)
returns table(missing_schools integer, missing_rows integer, message_text text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_ids uuid[]; v_markaz text; v_lines text; v_schools int; v_rows int; v_period text; v_text text; v_link text;
begin
  select coalesce(array_agg(sc.id), '{}'::uuid[]) into v_ids
  from public.schools sc join public.markaz m on m.id = sc.markaz_id
  where sc.active and m.tehsil = p_tehsil and (p_wing is null or sc.wing = p_wing);

  select string_agg(x.name, ', ' order by x.name) into v_markaz
  from (select distinct m.name from public.markaz m join public.schools sc on sc.markaz_id = m.id
        where sc.active and m.tehsil = p_tehsil and (p_wing is null or sc.wing = p_wing)) x;

  with miss as (select * from public.fn_missing_consumption_period(v_ids, p_from, p_to)),
       sch as (select markaz_name, school_id, emis_code, school_name,
                      string_agg(to_char(missing_date, 'DD Mon') || ' - ' || product_name, '; ' order by missing_date, product_name) items
               from miss group by markaz_name, school_id, emis_code, school_name),
       per as (select markaz_name, count(*) n,
                      string_agg('  * ' || school_name || ' (' || emis_code || '): ' || items, E'\n' order by school_name) lines
               from sch group by markaz_name)
  select coalesce((select count(*) from sch), 0),
         coalesce((select count(*) from miss), 0),
         coalesce((select string_agg('- ' || markaz_name || ': ' || n || ' school(s)' || E'\n' || lines, E'\n' order by n desc, markaz_name) from per), '')
  into v_schools, v_rows, v_lines;

  select app_link into v_link from public.wa_settings where id;

  v_period := case when p_from = p_to then to_char(p_from, 'DD Mon YYYY')
                   else to_char(p_from, 'DD Mon YYYY') || ' to ' || to_char(p_to, 'DD Mon YYYY') end;
  v_text := 'SMP Missing Consumption' || E'\n' ||
            'Tehsil: ' || p_tehsil || E'\n' ||
            'Markaz: ' || coalesce(v_markaz, '-') || E'\n' ||
            'Wing: ' || coalesce(p_wing, 'All') || E'\n' ||
            'Date: ' || v_period || E'\n' ||
            'Schools with missing entries: ' || v_schools || E'\n\n' ||
            'Markaz-wise (school: date - product):' || E'\n' || v_lines || E'\n\n' ||
            'Please update the pending entries in SMP Ledger.' || E'\n' ||
            coalesce(v_link, '');
  return query select v_schools, v_rows, v_text;
end $$;

revoke execute on function public.fn_wa_build(text,text,date,date) from public, anon, authenticated;
grant execute on function public.fn_wa_build(text,text,date,date) to service_role;
