-- Company vs AEO vs Head Teacher reported data on SMP (portal): one row per school + product + invoice/challan number.
create or replace view public.v_three_way_receipts with (security_invoker = true) as
with c as (
  select s.emis_code, case when lower(pr.product_name) like '%milk%' then 'milk' else 'biscuit' end product,
         public.fn_norm_invoice(i.invoice_number) k, max(i.invoice_number) inv, sum(it.quantity) qty, min(coalesce(i.delivery_date, i.invoice_date)) d
    from public.company_invoice_items it
    join public.company_invoices i on i.id = it.invoice_id and coalesce(i.status,'active') not in ('void','voided','cancelled')
    join public.schools s on s.id = it.school_id
    join public.products pr on pr.id = it.product_id
   group by 1,2,3),
a as (
  select s.emis_code, case when lower(pr.product_name) like '%milk%' then 'milk' else 'biscuit' end product,
         public.fn_norm_invoice(r.invoice_number) k, max(r.invoice_number) inv, sum(r.quantity_received) qty, min(r.receipt_date) d
    from public.school_receipts r
    join public.schools s on s.id = r.school_id
    join public.products pr on pr.id = r.product_id
   where coalesce(r.status,'active') not in ('void','voided','cancelled')
   group by 1,2,3),
p as (
  select emis_code, product, challan_norm k, max(challan_no) inv, sum(quantity) qty, min(receipt_date) d
    from public.portal_receipts group by 1,2,3),
j as (
  select coalesce(c.emis_code, a.emis_code, p.emis_code) emis_code, coalesce(c.product, a.product, p.product) product,
         coalesce(c.k, a.k, p.k) k,
         coalesce(c.inv, a.inv, p.inv) invoice_no, coalesce(c.d, p.d, a.d) receipt_date,
         c.qty company_qty, a.qty aeo_qty, p.qty portal_qty,
         (c.k is not null) in_company, (a.k is not null) in_aeo, (p.k is not null) in_portal
    from c
    full join a on a.emis_code = c.emis_code and a.product = c.product and a.k = c.k
    full join p on p.emis_code = coalesce(c.emis_code, a.emis_code) and p.product = coalesce(c.product, a.product) and p.k = coalesce(c.k, a.k))
select j.emis_code, s.school_name, j.product, j.invoice_no, j.receipt_date, j.company_qty, j.aeo_qty, j.portal_qty,
       j.in_company, j.in_aeo, j.in_portal,
       case
         when in_company and in_aeo and in_portal and company_qty = aeo_qty and aeo_qty = portal_qty then 'all_match'
         when not in_company and not in_aeo then 'portal_only'
         when not in_company and not in_portal then 'aeo_only'
         when not in_aeo and not in_portal then 'company_only'
         when not in_portal then case when company_qty = aeo_qty then 'not_on_portal' else 'company_aeo_differ' end
         when not in_aeo then case when company_qty = portal_qty then 'not_entered_by_aeo' else 'company_portal_differ' end
         when not in_company then case when aeo_qty = portal_qty then 'not_in_company_list' else 'aeo_portal_differ' end
         else 'quantities_differ' end as result
  from j left join public.schools s on s.emis_code = j.emis_code;
grant select on public.v_three_way_receipts to authenticated;
