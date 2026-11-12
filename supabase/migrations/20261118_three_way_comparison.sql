-- Company vs AEO vs Head Teacher (as reported on the SMP portal) comparison.
-- Head teacher side = portal_receipts, matched on school + product + normalised challan/invoice number.

drop policy if exists portal_runs_read on public.portal_sync_runs;
create policy portal_runs_read on public.portal_sync_runs for select to authenticated using (public.fn_is_admin_or_tr());
drop policy if exists portal_receipts_read on public.portal_receipts;
create policy portal_receipts_read on public.portal_receipts for select to authenticated
  using (public.fn_is_admin_or_tr() or exists (select 1 from public.schools s where s.emis_code = portal_receipts.emis_code and s.assigned_aeo_id = auth.uid()));
drop policy if exists portal_cons_read on public.portal_consumption;
create policy portal_cons_read on public.portal_consumption for select to authenticated
  using (public.fn_is_admin_or_tr() or exists (select 1 from public.schools s where s.emis_code = portal_consumption.emis_code and s.assigned_aeo_id = auth.uid()));

create or replace view public.v_three_way_comparison with (security_invoker = true) as
with p as (
  select s.id school_id, pr.id product_id, pt.challan_norm k,
         min(pt.challan_no) head_challan, min(pt.receipt_date) head_date, sum(pt.quantity) head_qty
    from public.portal_receipts pt
    join public.schools s on s.emis_code = pt.emis_code
    join public.products pr on lower(pr.product_name) like '%' || pt.product || '%'
   where pt.challan_norm <> ''
   group by 1, 2, 3),
b as (
  select v.*, coalesce(nullif(public.fn_norm_invoice(coalesce(v.company_invoice_number, '')), ''),
                       nullif(public.fn_norm_invoice(coalesce(v.aeo_invoice_number, '')), ''), '~') k
    from public.v_company_vs_aeo_comparison v),
j as (
  select b.invoice_number, b.invoice_date, b.delivery_date, b.school_id, b.product_id, b.company_qty, b.aeo_qty,
         b.difference, b.status, b.aeo_verification_status, b.company_invoice_number, b.aeo_invoice_number,
         b.remarks, b.aeo_flag, p.head_challan, p.head_date, p.head_qty
    from b left join p on p.school_id = b.school_id and p.product_id = b.product_id and p.k = b.k
  union all
  select p.head_challan, null, p.head_date, p.school_id, p.product_id, 0, 0, 0,
         'Head teacher reported, no company or AEO record', null, null, null, null, null,
         p.head_challan, p.head_date, p.head_qty
    from p
   where not exists (select 1 from b where b.school_id = p.school_id and b.product_id = p.product_id and b.k = p.k))
select j.*,
  case
    when j.head_qty is null and j.company_qty > 0 and j.aeo_qty > 0 then 'Head teacher has not reported'
    when j.head_qty is null then 'No head teacher report'
    when j.company_qty > 0 and j.aeo_qty > 0 and j.head_qty = j.company_qty and j.head_qty = j.aeo_qty then 'All three match'
    when j.company_qty = 0 and j.aeo_qty = 0 then 'Head teacher only'
    when j.company_qty > 0 and j.head_qty <> j.company_qty and j.aeo_qty > 0 and j.head_qty = j.aeo_qty then 'Head teacher and AEO agree, differ from company'
    when j.company_qty > 0 and j.head_qty = j.company_qty and j.aeo_qty > 0 and j.head_qty <> j.aeo_qty then 'Head teacher and company agree, differ from AEO'
    when j.company_qty > 0 and j.head_qty = j.company_qty then 'Head teacher matches company, AEO missing'
    when j.aeo_qty > 0 and j.head_qty = j.aeo_qty then 'Head teacher matches AEO, company missing'
    else 'Quantities differ' end as three_way_status
from j;
grant select on public.v_three_way_comparison to authenticated;
