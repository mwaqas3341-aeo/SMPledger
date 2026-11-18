-- Three-way decisions: settle a Company vs AEO vs Head teacher issue by recording WHICH SIDE IS WRONG, WHICH SIDE IS RIGHT
-- (quantity and/or invoice number), optionally PAIRING the row with another invoice of the same school, plus a mandatory reason.
--
-- Nothing in the company, AEO or head-teacher (portal) data is edited. The decision is an audited overlay:
--   public.three_way_decisions      one row per decision (who/when/why, soft-revoked via active=false)
--   public.three_way_decision_rows  the comparison rows a decision covers (school + product + invoice key + head challan key)
--   v_three_way_comparison          rows covered by an active decision show "Settled manually: ..." and no longer count as issues
--                                   (extra columns decision_id, decision_note appended at the end; every existing column unchanged)
-- Pairing a head-teacher challan with a company/AEO invoice also writes the existing pair_head settlement so v_three_way_base
-- really pairs the two rows. Writes only through fn_decide_three_way / fn_undo_three_way_decision (admin only).

create table if not exists public.three_way_decisions (
  id bigserial primary key,
  school_id uuid not null references public.schools(id),
  product_id uuid not null references public.products(id),
  wrong_sides text[] not null default '{}',
  qty_issue boolean not null default false,
  right_qty numeric,
  qty_source text,
  invoice_issue boolean not null default false,
  right_invoice text,
  invoice_source text,
  pair_label text,
  reason text not null,
  short_label text not null,
  note text not null,
  settlement_ids bigint[] not null default '{}',
  decided_by uuid,
  decided_by_name text,
  decided_at timestamptz not null default now(),
  active boolean not null default true,
  revoked_by uuid,
  revoked_at timestamptz,
  constraint twd_reason_len check (char_length(btrim(reason)) >= 5),
  constraint twd_sides check (wrong_sides <@ array['company','aeo','head']),
  constraint twd_qty_src check (qty_source is null or qty_source in ('company','aeo','head','custom')),
  constraint twd_inv_src check (invoice_source is null or invoice_source in ('company','aeo','head'))
);
create table if not exists public.three_way_decision_rows (
  decision_id bigint not null references public.three_way_decisions(id) on delete cascade,
  school_id uuid not null,
  product_id uuid not null,
  row_key text not null,
  head_key text not null default ''
);
create index if not exists twdr_lookup on public.three_way_decision_rows (school_id, product_id, row_key, head_key);
create index if not exists twd_active_school on public.three_way_decisions (school_id, product_id) where active;

alter table public.three_way_decisions enable row level security;
alter table public.three_way_decision_rows enable row level security;
drop policy if exists twd_read on public.three_way_decisions;
create policy twd_read on public.three_way_decisions for select
  using ((select public.fn_is_admin_or_tr()) or exists (select 1 from public.schools s where s.id = three_way_decisions.school_id));
drop policy if exists twdr_read on public.three_way_decision_rows;
create policy twdr_read on public.three_way_decision_rows for select
  using ((select public.fn_is_admin_or_tr()) or exists (select 1 from public.schools s where s.id = three_way_decision_rows.school_id));
grant select on public.three_way_decisions, public.three_way_decision_rows to authenticated;

-- p_row / p_pair: {"company_invoice": "...", "aeo_invoice": "...", "head_challan": "...", "label": "..."} (raw text as shown in the comparison).
create or replace function public.fn_decide_three_way(
  p_emis text, p_product_id uuid, p_row jsonb,
  p_wrong text[], p_qty_issue boolean, p_right_qty numeric, p_qty_source text,
  p_invoice_issue boolean, p_right_invoice text, p_invoice_source text,
  p_pair jsonb, p_reason text)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare
  v_school uuid; v_id bigint; v_name text; v_reason text := btrim(coalesce(p_reason,''));
  rk text; hk text; prk text; phk text; v_sid bigint; v_sids bigint[] := '{}';
  v_short text; v_note text; v_wrong text[] := coalesce(p_wrong, '{}'); w text; parts text[] := '{}';
begin
  if not public.fn_is_admin() then raise exception 'Only an admin can settle three-way entries'; end if;
  select id into v_school from public.schools where emis_code = btrim(p_emis);
  if v_school is null then raise exception 'Unknown EMIS code %', p_emis; end if;
  if char_length(v_reason) < 5 then raise exception 'Please write the reason (at least 5 characters)'; end if;
  foreach w in array v_wrong loop
    if w not in ('company','aeo','head') then raise exception 'Unknown side %', w; end if;
  end loop;
  if not (coalesce(p_qty_issue,false) or coalesce(p_invoice_issue,false) or p_pair is not null or cardinality(v_wrong) > 0) then
    raise exception 'Choose what is wrong, the right value, or an invoice to pair with';
  end if;
  if coalesce(p_qty_issue,false) then
    if p_qty_source not in ('company','aeo','head','custom') then raise exception 'Choose which quantity is right'; end if;
    if p_right_qty is null or p_right_qty < 0 then raise exception 'Right quantity is missing'; end if;
    if p_qty_source <> 'custom' and p_qty_source = any (v_wrong) then raise exception 'The right quantity cannot come from a side marked wrong'; end if;
  end if;
  if coalesce(p_invoice_issue,false) then
    if p_invoice_source not in ('company','aeo','head') then raise exception 'Choose which invoice number is right'; end if;
    if nullif(btrim(coalesce(p_right_invoice,'')),'') is null then raise exception 'Right invoice number is missing'; end if;
    if p_invoice_source = any (v_wrong) then raise exception 'The right invoice number cannot come from a side marked wrong'; end if;
  end if;

  rk := coalesce(nullif(public.fn_norm_invoice(coalesce(p_row->>'company_invoice','')),''), nullif(public.fn_norm_invoice(coalesce(p_row->>'aeo_invoice','')),''), '~');
  hk := coalesce(public.fn_norm_invoice(coalesce(p_row->>'head_challan','')), '');
  select full_name into v_name from public.profiles where id = auth.uid();

  if cardinality(v_wrong) > 0 then parts := parts || ('Wrong: ' || array_to_string(array(select case x when 'company' then 'Company' when 'aeo' then 'AEO' else 'Head teacher' end from unnest(v_wrong) x), ', ')); end if;
  if coalesce(p_qty_issue,false) then parts := parts || ('Right quantity ' || trim_scale(p_right_qty)::text || ' (' || case p_qty_source when 'custom' then 'entered' else p_qty_source end || ')'); end if;
  if coalesce(p_invoice_issue,false) then parts := parts || ('Right invoice ' || btrim(p_right_invoice) || ' (' || p_invoice_source || ')'); end if;
  if p_pair is not null then parts := parts || ('Paired with ' || coalesce(nullif(p_pair->>'label',''), 'another invoice')); end if;
  v_short := coalesce(array_to_string(parts, '; '), '') ;
  insert into public.three_way_decisions (school_id, product_id, wrong_sides, qty_issue, right_qty, qty_source, invoice_issue, right_invoice, invoice_source,
      pair_label, reason, short_label, note, decided_by, decided_by_name)
  values (v_school, p_product_id, v_wrong, coalesce(p_qty_issue,false), p_right_qty, p_qty_source, coalesce(p_invoice_issue,false),
      nullif(btrim(coalesce(p_right_invoice,'')),''), p_invoice_source, p_pair->>'label', v_reason, v_short, '', auth.uid(), v_name)
  returning id into v_id;
  v_note := 'Settled manually: ' || v_short || '. Reason: ' || v_reason || ' (' || coalesce(v_name,'admin') || ', ' || to_char(now(), 'DD-Mon-YYYY') || ')';
  update public.three_way_decisions set note = v_note where id = v_id;

  insert into public.three_way_decision_rows values (v_id, v_school, p_product_id, rk, hk);
  if p_pair is not null then
    prk := coalesce(nullif(public.fn_norm_invoice(coalesce(p_pair->>'company_invoice','')),''), nullif(public.fn_norm_invoice(coalesce(p_pair->>'aeo_invoice','')),''), '~');
    phk := coalesce(public.fn_norm_invoice(coalesce(p_pair->>'head_challan','')), '');
    insert into public.three_way_decision_rows values (v_id, v_school, p_product_id, prk, phk);
    -- head-teacher challan on one side and a company/AEO invoice on the other: let the matcher pair them for real
    if rk = '~' and hk <> '' and prk <> '~' then
      insert into public.three_way_settlements (school_id, product_id, action, invoice_key, head_key, reason, settled_by, settled_by_name)
      values (v_school, p_product_id, 'pair_head', prk, hk, 'Decision #' || v_id || ': ' || v_reason, auth.uid(), v_name) returning id into v_sid;
      v_sids := v_sids || v_sid;
      insert into public.three_way_decision_rows values (v_id, v_school, p_product_id, prk, hk);
    elsif prk = '~' and phk <> '' and rk <> '~' then
      insert into public.three_way_settlements (school_id, product_id, action, invoice_key, head_key, reason, settled_by, settled_by_name)
      values (v_school, p_product_id, 'pair_head', rk, phk, 'Decision #' || v_id || ': ' || v_reason, auth.uid(), v_name) returning id into v_sid;
      v_sids := v_sids || v_sid;
      insert into public.three_way_decision_rows values (v_id, v_school, p_product_id, rk, phk);
    end if;
    update public.three_way_decisions set settlement_ids = v_sids where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function public.fn_undo_three_way_decision(p_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.fn_is_admin() then raise exception 'Only an admin can undo a settlement'; end if;
  update public.three_way_settlements set active = false, revoked_by = auth.uid(), revoked_at = now()
   where active and id = any (select unnest(settlement_ids) from public.three_way_decisions where id = p_id);
  update public.three_way_decisions set active = false, revoked_by = auth.uid(), revoked_at = now() where id = p_id and active;
end $$;
revoke all on function public.fn_decide_three_way(text, uuid, jsonb, text[], boolean, numeric, text, boolean, text, text, jsonb, text) from public, anon;
revoke all on function public.fn_undo_three_way_decision(bigint) from public, anon;
grant execute on function public.fn_decide_three_way(text, uuid, jsonb, text[], boolean, numeric, text, boolean, text, text, jsonb, text) to authenticated;
grant execute on function public.fn_undo_three_way_decision(bigint) to authenticated;

create or replace view public.v_three_way_comparison with (security_invoker = true) as
 WITH base AS MATERIALIZED (
         SELECT v_three_way_base.invoice_number, v_three_way_base.invoice_date, v_three_way_base.delivery_date, v_three_way_base.school_id,
            v_three_way_base.product_id, v_three_way_base.company_qty, v_three_way_base.aeo_qty, v_three_way_base.difference,
            v_three_way_base.status, v_three_way_base.aeo_verification_status, v_three_way_base.company_invoice_number,
            v_three_way_base.aeo_invoice_number, v_three_way_base.remarks, v_three_way_base.aeo_flag, v_three_way_base.head_challan,
            v_three_way_base.head_date, v_three_way_base.head_qty, v_three_way_base.three_way_status,
            v_three_way_base.head_invoice_differs, v_three_way_base.head_note
           FROM v_three_way_base
        ), rr AS MATERIALIZED (
         SELECT r.id, r.product_name, r.through_date FROM inventory_total_match_rules r WHERE r.active
        ), st AS MATERIALIZED (
         SELECT DISTINCT x.school_id, x.product_id
           FROM ( SELECT b_1.school_id, b_1.product_id, r.id AS rule_id
                   FROM base b_1
                     JOIN products pp ON pp.id = b_1.product_id
                     JOIN rr r ON lower(pp.product_name) ~~ (lower(r.product_name) || '%'::text)
                  WHERE COALESCE(b_1.delivery_date, b_1.head_date) <= r.through_date
                  GROUP BY b_1.school_id, b_1.product_id, r.id
                 HAVING sum(b_1.company_qty) = sum(b_1.aeo_qty) AND sum(b_1.aeo_qty) = COALESCE(sum(b_1.head_qty), 0::numeric) AND sum(b_1.aeo_qty) > 0::numeric) x
        ), pr AS MATERIALIZED (
         SELECT pp.id AS product_id, max(r.through_date) AS through_date
           FROM products pp JOIN rr r ON lower(pp.product_name) ~~ (lower(r.product_name) || '%'::text)
          GROUP BY pp.id
        ), dc AS MATERIALIZED (
         SELECT r.school_id, r.product_id, r.row_key, r.head_key, max(d.id) AS id
           FROM three_way_decision_rows r JOIN three_way_decisions d ON d.id = r.decision_id AND d.active
          GROUP BY r.school_id, r.product_id, r.row_key, r.head_key
        )
 SELECT b.invoice_number, b.invoice_date, b.delivery_date, b.school_id, b.product_id, b.company_qty, b.aeo_qty,
        CASE WHEN dd.id IS NOT NULL OR s.settled THEN 0::numeric ELSE b.difference END AS difference,
        CASE WHEN dd.id IS NOT NULL OR s.settled THEN 'Matched'::text ELSE b.status END AS status,
    b.aeo_verification_status, b.company_invoice_number, b.aeo_invoice_number,
        CASE WHEN dd.id IS NOT NULL OR s.settled THEN NULL::text ELSE b.remarks END AS remarks,
        CASE WHEN dd.id IS NOT NULL OR s.settled THEN NULL::text ELSE b.aeo_flag END AS aeo_flag,
    b.head_challan, b.head_date, b.head_qty,
        CASE WHEN dd.id IS NOT NULL THEN 'Settled manually, decision #' || dd.id::text
             WHEN s.settled AND b.three_way_status <> 'All three match'::text THEN 'Matched on school total'::text
             ELSE b.three_way_status END AS three_way_status,
        CASE WHEN dd.id IS NOT NULL OR s.settled THEN false ELSE b.head_invoice_differs END AS head_invoice_differs,
        CASE WHEN dd.id IS NOT NULL THEN dn.note WHEN s.settled THEN NULL::text ELSE b.head_note END AS head_note,
    (s.settled OR dd.id IS NOT NULL) AS settled_on_totals,
    dd.id AS decision_id,
    dn.note AS decision_note
   FROM base b
     LEFT JOIN pr ON pr.product_id = b.product_id
     LEFT JOIN st ON st.school_id = b.school_id AND st.product_id = b.product_id
     LEFT JOIN dc dd ON dd.school_id = b.school_id AND dd.product_id = b.product_id
          AND dd.row_key = COALESCE(NULLIF(fn_norm_invoice(COALESCE(b.company_invoice_number, ''::text)), ''::text), NULLIF(fn_norm_invoice(COALESCE(b.aeo_invoice_number, ''::text)), ''::text), '~'::text)
          AND dd.head_key = COALESCE(fn_norm_invoice(COALESCE(b.head_challan, ''::text)), ''::text)
     LEFT JOIN three_way_decisions dn ON dn.id = dd.id
     CROSS JOIN LATERAL ( SELECT st.school_id IS NOT NULL AND pr.through_date IS NOT NULL AND COALESCE(b.delivery_date, b.head_date) <= pr.through_date AS settled) s;
grant select on public.v_three_way_comparison to authenticated;
