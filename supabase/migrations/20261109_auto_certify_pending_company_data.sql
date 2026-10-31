-- AEO certification of company data: certify AUTOMATICALLY, for everyone, whenever the company row matches the AEO receipt.
-- Until now certification only ran from two moments (the admin's browser right after an import, and when an AEO saved a receipt).
-- If the browser step was interrupted or skipped, matching rows stayed "pending" for ever (62 rows on 31 Oct, all exact matches).
-- This sweep runs in the database every 5 minutes, needs nobody to be logged in, and uses the same rule as before:
--   same school + same product + same invoice number (letters/digits only, O = 0) + equal total quantity
--   (rows with no invoice number are matched by delivery/receipt date instead).
-- Rows that do NOT match stay pending (or flagged) for a person to look at. Locked periods are never touched.
-- Run in the SQL editor. Safe to run more than once.

create or replace function public.fn_auto_certify_pending(p_dry_run boolean default false) returns integer
language plpgsql security definer set search_path = public as $$
declare r record; v_key text; v_cq numeric; v_aq numeric; v_n integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('auto_certify_pending'));
  for r in
    select cii.invoice_id, cii.school_id, cii.product_id, ci.invoice_number, ci.delivery_date
      from public.company_invoice_items cii
      join public.company_invoices ci on ci.id = cii.invoice_id and ci.status = 'active'
     where cii.aeo_verification_status in ('pending', 'flagged_mismatch')
     group by cii.invoice_id, cii.school_id, cii.product_id, ci.invoice_number, ci.delivery_date
  loop
    begin
      v_key := coalesce(public.fn_norm_invoice(r.invoice_number), 'DATE:' || r.delivery_date::text);
      select sum(cii2.quantity) into v_cq
        from public.company_invoice_items cii2
        join public.company_invoices ci2 on ci2.id = cii2.invoice_id and ci2.status = 'active'
       where cii2.school_id = r.school_id and cii2.product_id = r.product_id
         and coalesce(public.fn_norm_invoice(ci2.invoice_number), 'DATE:' || ci2.delivery_date::text) = v_key;
      select sum(sr.quantity_received) into v_aq
        from public.school_receipts sr
       where sr.school_id = r.school_id and sr.product_id = r.product_id and sr.status = 'active'
         and coalesce(public.fn_norm_invoice(sr.invoice_number), 'DATE:' || sr.receipt_date::text) = v_key;
      if v_aq is not null and v_aq = v_cq then
        v_n := v_n + 1;
        if not p_dry_run then
          update public.company_invoice_items cii
             set aeo_verification_status = 'received', aeo_verified_at = now(),
                 aeo_verification_remarks = 'Auto-certified: matched AEO receipt (same school, product, invoice and quantity)'
            from public.company_invoices ci
           where cii.invoice_id = ci.id and ci.status = 'active'
             and cii.school_id = r.school_id and cii.product_id = r.product_id
             and cii.aeo_verification_status in ('pending', 'flagged_mismatch')
             and coalesce(public.fn_norm_invoice(ci.invoice_number), 'DATE:' || ci.delivery_date::text) = v_key;
        end if;
      end if;
    exception when others then
      null;     -- one row that cannot be certified (for example a locked period) must not stop the others
    end;
  end loop;
  return v_n;
end $$;

revoke all on function public.fn_auto_certify_pending(boolean) from public, anon, authenticated;
grant execute on function public.fn_auto_certify_pending(boolean) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('auto-certify-pending') where exists (select 1 from cron.job where jobname = 'auto-certify-pending');
    perform cron.schedule('auto-certify-pending', '*/5 * * * *', 'select public.fn_auto_certify_pending()');
  end if;
end $$;

select public.fn_auto_certify_pending() as groups_certified_now;
