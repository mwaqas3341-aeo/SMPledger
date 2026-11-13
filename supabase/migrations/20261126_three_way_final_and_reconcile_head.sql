-- Final live definitions (already applied via MCP). Head-teacher invoice typos (e.g. DD0445INV166555 for DD0445INV16655):
-- an unmatched head receipt is paired 1:1 with the company/AEO row of the same school + product + quantity when
--   dates are within 3 days, or numbers are within 3 edits and dates within 10 days,
--   or (non-milk) dates within 7 days, or within 30 days with numbers within 2 edits.
-- Paired rows count as matching with the remark "cannot be corrected on SMP"; unpaired rows stay flagged for review.
create extension if not exists fuzzystrmatch with schema extensions;
drop view if exists public.v_three_way_comparison;
create view public.v_three_way_comparison with (security_invoker = true) as
with p as (
  select row_number() over (order by s.id, pr.id, pt.challan_norm) pid, s.id school_id, pr.id product_id, pt.challan_norm k,
         min(pt.challan_no) head_challan, min(pt.receipt_date) head_date, sum(pt.quantity) head_qty
    from public.portal_receipts pt
    join public.schools s on s.emis_code = pt.emis_code
    join public.products pr on lower(pr.product_name) like '%' || pt.product || '%'
   where pt.challan_norm <> ''
   group by s.id, pr.id, pt.challan_norm),
rn as (
  select sr.school_id, sr.product_id, public.fn_norm_invoice(sr.invoice_number) k, string_agg(distinct sr.reconciled_note, ' | ') note
    from public.school_receipts sr where sr.status = 'active' and sr.reconciled_note is not null
   group by 1, 2, 3),
b as (
  select row_number() over (order by v.delivery_date, v.school_id, v.product_id, v.invoice_number) bid, v.*,
         coalesce(nullif(public.fn_norm_invoice(coalesce(v.company_invoice_number, '')), ''),
                  nullif(public.fn_norm_invoice(coalesce(v.aeo_invoice_number, '')), ''), '~') k
    from public.v_company_vs_aeo_comparison v),
m1 as (select b.bid, p.pid from b join p on p.school_id = b.school_id and p.product_id = b.product_id and p.k = b.k),
bu as (select * from b where bid not in (select bid from m1)),
pu as (select * from p where pid not in (select pid from m1)),
cand as (
  select bu.bid, pu.pid, extensions.levenshtein(pu.k, bu.k) ed, abs(pu.head_date - bu.delivery_date) dd
    from bu join pu on pu.school_id = bu.school_id and pu.product_id = bu.product_id
    join public.products prd on prd.id = bu.product_id
     and pu.head_qty = case when bu.company_qty > 0 then bu.company_qty else bu.aeo_qty end
   where abs(pu.head_date - bu.delivery_date) <= 3
      or (abs(pu.head_date - bu.delivery_date) <= 10 and extensions.levenshtein(pu.k, bu.k) <= 3)
      or (lower(prd.product_name) not like 'milk%'
          and (abs(pu.head_date - bu.delivery_date) <= 7
               or (abs(pu.head_date - bu.delivery_date) <= 30 and extensions.levenshtein(pu.k, bu.k) <= 2)))),
rk as (select bid, pid,
        row_number() over (partition by bid order by ed, dd, pid) rb,
        row_number() over (partition by pid order by ed, dd, bid) rp from cand),
m2 as (select bid, pid from rk where rb = 1 and rp = 1),
mm as (select bid, pid, false fuzzy from m1 union all select bid, pid, true from m2),
j as (
  select b.invoice_number, b.invoice_date, b.delivery_date, b.school_id, b.product_id, b.company_qty, b.aeo_qty,
         b.difference, b.status, b.aeo_verification_status, b.company_invoice_number, b.aeo_invoice_number,
         b.remarks, b.aeo_flag, p.head_challan, p.head_date, p.head_qty, coalesce(mm.fuzzy, false) head_invoice_differs, rn.note recon_note
    from b left join mm on mm.bid = b.bid left join p on p.pid = mm.pid
         left join rn on rn.school_id = b.school_id and rn.product_id = b.product_id and rn.k = b.k
  union all
  select p.head_challan, null::date, p.head_date, p.school_id, p.product_id, 0::numeric, 0::numeric, 0::numeric,
         'Head teacher reported, no company or AEO record', null::text, null::text, null::text, null::text, null::text,
         p.head_challan, p.head_date, p.head_qty, false, null::text
    from p where p.pid not in (select pid from mm))
select j.invoice_number, j.invoice_date, j.delivery_date, j.school_id, j.product_id, j.company_qty, j.aeo_qty, j.difference, j.status,
  j.aeo_verification_status, j.company_invoice_number, j.aeo_invoice_number, j.remarks, j.aeo_flag,
  j.head_challan, j.head_date, j.head_qty,
  case
    when j.head_qty is null and j.company_qty > 0 and j.aeo_qty > 0 then 'Head teacher has not reported'
    when j.head_qty is null then 'No head teacher report'
    when j.company_qty > 0 and j.aeo_qty > 0 and j.head_qty = j.company_qty and j.head_qty = j.aeo_qty then 'All three match'
    when j.company_qty = 0 and j.aeo_qty = 0 then 'Head teacher only'
    when j.company_qty > 0 and j.head_qty <> j.company_qty and j.aeo_qty > 0 and j.head_qty = j.aeo_qty then 'Head teacher and AEO agree, differ from company'
    when j.company_qty > 0 and j.head_qty = j.company_qty and j.aeo_qty > 0 and j.head_qty <> j.aeo_qty then 'Head teacher and company agree, differ from AEO'
    when j.company_qty > 0 and j.head_qty = j.company_qty then 'Head teacher matches company, AEO missing'
    when j.aeo_qty > 0 and j.head_qty = j.aeo_qty then 'Head teacher matches AEO, company missing'
    else 'Quantities differ' end as three_way_status,
  j.head_invoice_differs,
  nullif(concat_ws(' ',
    case when j.head_invoice_differs then 'Head teacher challan # "' || j.head_challan || '" differs from the invoice number (cannot be corrected on SMP); paired on school, product and quantity with a near-identical number or date.' end,
    j.recon_note), '') as head_note
from j;
grant select on public.v_three_way_comparison to authenticated;
-- fn_reconcile_with_head(p_dry_run boolean): see pg_get_functiondef('public.fn_reconcile_with_head(boolean)'::regprocedure) for the live text.
