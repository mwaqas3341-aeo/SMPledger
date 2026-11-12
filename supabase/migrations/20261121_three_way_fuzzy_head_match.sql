-- Head teachers cannot correct a wrongly typed challan number on SMP, so a head teacher receipt whose number
-- does not match is paired with a company/AEO row of the same school + product + quantity dated within 7 days
-- (closest pair, both ways). Such rows count as matching; head_invoice_differs says the number was not the same.
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
b as (
  select row_number() over (order by v.delivery_date, v.school_id, v.product_id, v.invoice_number) bid, v.*,
         coalesce(nullif(public.fn_norm_invoice(coalesce(v.company_invoice_number, '')), ''),
                  nullif(public.fn_norm_invoice(coalesce(v.aeo_invoice_number, '')), ''), '~') k
    from public.v_company_vs_aeo_comparison v),
m1 as (select b.bid, p.pid from b join p on p.school_id = b.school_id and p.product_id = b.product_id and p.k = b.k),
bu as (select * from b where bid not in (select bid from m1)),
pu as (select * from p where pid not in (select pid from m1)),
cand as (
  select bu.bid, pu.pid, abs(pu.head_date - bu.delivery_date) dd
    from bu join pu on pu.school_id = bu.school_id and pu.product_id = bu.product_id
     and pu.head_qty = case when bu.company_qty > 0 then bu.company_qty else bu.aeo_qty end
     and abs(pu.head_date - bu.delivery_date) <= 7),
rk as (select bid, pid, row_number() over (partition by bid order by dd, pid) rb, row_number() over (partition by pid order by dd, bid) rp from cand),
m2 as (select bid, pid from rk where rb = 1 and rp = 1),
mm as (select bid, pid, false fuzzy from m1 union all select bid, pid, true from m2),
j as (
  select b.invoice_number, b.invoice_date, b.delivery_date, b.school_id, b.product_id, b.company_qty, b.aeo_qty,
         b.difference, b.status, b.aeo_verification_status, b.company_invoice_number, b.aeo_invoice_number,
         b.remarks, b.aeo_flag, p.head_challan, p.head_date, p.head_qty, coalesce(mm.fuzzy, false) head_invoice_differs
    from b left join mm on mm.bid = b.bid left join p on p.pid = mm.pid
  union all
  select p.head_challan, null::date, p.head_date, p.school_id, p.product_id, 0::numeric, 0::numeric, 0::numeric,
         'Head teacher reported, no company or AEO record', null::text, null::text, null::text, null::text, null::text,
         p.head_challan, p.head_date, p.head_qty, false
    from p where p.pid not in (select pid from mm))
select j.invoice_number, j.invoice_date, j.delivery_date, j.school_id, j.product_id, j.company_qty, j.aeo_qty, j.difference, j.status,
  j.aeo_verification_status, j.company_invoice_number, j.aeo_invoice_number,
  j.remarks,
  j.aeo_flag, j.head_challan, j.head_date, j.head_qty,
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
  case when j.head_invoice_differs then 'Head teacher challan # "' || j.head_challan || '" differs from the invoice number (cannot be corrected on SMP); paired on school, product, quantity and date.' end as head_note
from j;
grant select on public.v_three_way_comparison to authenticated;
