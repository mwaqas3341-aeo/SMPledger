import { createClient } from "npm:@supabase/supabase-js@2";

// Emails each markaz's AEO(s) a consumption report (Previous Balance / Consumed / Remaining
// per school and product) after consumption entries are saved.
//
// Flow: a trigger on `consumption` queues (school, date) in aeo_report_queue; pg_cron calls this
// function every minute when rows have waited 3+ minutes (so an AEO who is still entering
// several schools gets ONE email per markaz, not one per school). Delivery is via Brevo.
//
// Secrets (Supabase -> Edge Functions -> Secrets):
//   BREVO_API_KEY        required  (Brevo -> SMTP & API -> API Keys)
//   BREVO_SENDER_EMAIL   required  (must be a verified sender in Brevo -> Senders & IP)
//   BREVO_SENDER_NAME    optional  (default "SMP Reports")
//
// Auth: verify_jwt is on. The cron job calls with the project's public anon key; the function
// takes no recipient or content from the request, so a caller can only trigger sending of
// reports that are already queued. `test_email` mode additionally requires an admin session.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY");
const BREVO_SENDER_EMAIL = Deno.env.get("BREVO_SENDER_EMAIL");
const BREVO_SENDER_NAME = Deno.env.get("BREVO_SENDER_NAME") || "SMP Reports";

const DEBOUNCE_MINUTES = 3;      // keep in step with the cron job's WHERE clause
const STALE_AFTER_DAYS = 3;      // queued rows older than this are dropped, never emailed late
const MAX_ATTEMPTS = 3;
const BATCH_LIMIT = 200;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
function fmtDMY(d: string) {
  const [y, m, day] = d.split("-").map(Number);
  return `${day}-${MONTHS[m - 1]}-${y}`;
}
function num(n: number) {
  return (Math.round(Number(n) * 100) / 100).toLocaleString("en-US", { maximumFractionDigits: 2 });
}
function esc(s: unknown) {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" } as Record<string, string>)[c]);
}

type Line = { product: string; unit: string; opening: number; consumed: number; remaining: number };
type SchoolBlock = { school: string; emis: string; date: string; lines: Line[] };

function renderEmail(markazName: string, blocks: SchoolBlock[]) {
  const dates = [...new Set(blocks.map((b) => b.date))].sort();
  const range = dates.length === 1 ? fmtDMY(dates[0]) : `${fmtDMY(dates[0])} to ${fmtDMY(dates[dates.length - 1])}`;
  const th = "padding:8px 10px;border:1px solid #d9dee5;background:#f3f5f8;text-align:right;font-size:13px;";
  const td = "padding:8px 10px;border:1px solid #d9dee5;text-align:right;font-size:13px;";

  let html = `<div style="font-family:Arial,Helvetica,sans-serif;color:#1d2733;max-width:720px;">
    <h2 style="margin:0 0 4px;font-size:18px;">School Meal Program &ndash; Consumption Report</h2>
    <p style="margin:0 0 16px;color:#5b6775;font-size:13px;">Markaz <b>${esc(markazName)}</b> &middot; ${esc(range)}</p>`;
  let text = `School Meal Program - Consumption Report\nMarkaz: ${markazName}\n${range}\n`;

  for (const date of dates) {
    for (const b of blocks.filter((x) => x.date === date)) {
      html += `<p style="margin:18px 0 6px;font-size:14px;"><b>${esc(b.school)}</b>
        <span style="color:#5b6775;">(EMIS ${esc(b.emis)}) &middot; ${esc(fmtDMY(b.date))}</span></p>
        <table style="border-collapse:collapse;width:100%;">
        <tr><th style="${th}text-align:left;">Product</th><th style="${th}">Previous Balance</th>
        <th style="${th}">Consumed</th><th style="${th}">Remaining</th></tr>`;
      text += `\n${b.school} (EMIS ${b.emis}) - ${fmtDMY(b.date)}\n`;
      const notes: string[] = [];
      for (const l of b.lines) {
        html += `<tr><td style="${td}text-align:left;">${esc(l.product)}</td>
          <td style="${td}">${num(l.opening)} ${esc(l.unit)}</td>
          <td style="${td}">${num(l.consumed)} ${esc(l.unit)}</td>
          <td style="${td}"><b>${num(l.remaining)} ${esc(l.unit)}</b></td></tr>`;
        text += `  ${l.product}: previous ${num(l.opening)}, consumed ${num(l.consumed)}, remaining ${num(l.remaining)} ${l.unit}\n`;
        const other = l.remaining - (l.opening - l.consumed);
        if (Math.abs(other) > 0.005) {
          notes.push(`${l.product}: ${other > 0 ? "+" : ""}${num(other)} ${l.unit} received / transferred / adjusted that day`);
        }
      }
      html += `</table>`;
      if (notes.length) {
        html += `<p style="margin:6px 0 0;color:#5b6775;font-size:12px;">${notes.map(esc).join(" &middot; ")}</p>`;
        text += `  Note: ${notes.join("; ")}\n`;
      }
    }
  }
  html += `<p style="margin:22px 0 0;color:#8a94a1;font-size:12px;">Remaining = stock on hand after that day's activity. This is an automatic message from the School Meal Program system.</p></div>`;
  return { html, text, range };
}

async function sendBrevo(to: { email: string; name?: string }[], subject: string, html: string, text: string) {
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": BREVO_API_KEY!, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      sender: { name: BREVO_SENDER_NAME, email: BREVO_SENDER_EMAIL },
      to,
      subject,
      htmlContent: html,
      textContent: text,
      tags: ["smp-aeo-report"],
    }),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`Brevo ${res.status}: ${body.slice(0, 300)}`);
  return body;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  let body: any = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }

  // ---- Test mode: admin only. Sends a sample report to one address to verify Brevo setup. ----
  if (body?.test_email) {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer /, "");
    const { data: u } = await sb.auth.getUser(token);
    const { data: prof } = u?.user
      ? await sb.from("profiles").select("role, active").eq("id", u.user.id).single()
      : { data: null };
    if (!prof?.active || !["admin", "super_admin"].includes(prof.role)) return json({ error: "Admin session required" }, 403);
    if (!BREVO_API_KEY || !BREVO_SENDER_EMAIL) return json({ error: "BREVO_API_KEY / BREVO_SENDER_EMAIL secrets are not set" }, 400);
    const today = new Date().toISOString().slice(0, 10);
    const sample = renderEmail("SAMPLE MARKAZ", [{
      school: "GPS SAMPLE SCHOOL", emis: "00000000", date: today,
      lines: [
        { product: "Milk", unit: "packs", opening: 120, consumed: 40, remaining: 80 },
        { product: "Biscuits", unit: "packs", opening: 60, consumed: 25, remaining: 35 },
      ],
    }]);
    try {
      await sendBrevo([{ email: String(body.test_email) }], "SMP test report (sample data)", sample.html, sample.text);
      return json({ ok: true, sent_to: body.test_email });
    } catch (e) {
      return json({ error: String((e as Error).message) }, 502);
    }
  }

  // ---- Normal queue run ----
  const nowIso = new Date().toISOString();
  const staleCut = new Date(Date.now() - STALE_AFTER_DAYS * 86400000).toISOString();
  const debounceCut = new Date(Date.now() - DEBOUNCE_MINUTES * 60000).toISOString();

  // housekeeping: drop stale rows, requeue rows stuck in 'processing' (crashed run)
  await sb.from("aeo_report_queue").update({ status: "expired", last_error: "Not sent within 3 days" })
    .eq("status", "pending").lt("last_changed_at", staleCut);
  await sb.from("aeo_report_queue").update({ status: "pending" })
    .eq("status", "processing").lt("claimed_at", new Date(Date.now() - 10 * 60000).toISOString());

  if (!BREVO_API_KEY || !BREVO_SENDER_EMAIL) {
    return json({ ok: true, skipped: "Brevo is not configured yet (BREVO_API_KEY / BREVO_SENDER_EMAIL); queue left untouched" });
  }

  const { data: due, error: dueErr } = await sb.from("aeo_report_queue").select("id")
    .eq("status", "pending").lt("last_changed_at", debounceCut)
    .order("last_changed_at").limit(BATCH_LIMIT);
  if (dueErr) return json({ error: dueErr.message }, 500);
  if (!due?.length) return json({ ok: true, processed: 0 });

  // claim atomically so overlapping runs can never double-send
  const { data: claimed, error: claimErr } = await sb.from("aeo_report_queue")
    .update({ status: "processing", claimed_at: nowIso })
    .in("id", due.map((r: any) => r.id)).eq("status", "pending")
    .select("id, school_id, report_date, attempts");
  if (claimErr) return json({ error: claimErr.message }, 500);
  if (!claimed?.length) return json({ ok: true, processed: 0 });

  const schoolIds = [...new Set(claimed.map((r: any) => r.school_id))];
  const { data: schools } = await sb.from("schools")
    .select("id, school_name, emis_code, markaz_id").in("id", schoolIds);
  const schoolById = new Map((schools || []).map((s: any) => [s.id, s]));
  const markazIds = [...new Set((schools || []).map((s: any) => s.markaz_id))];
  const { data: markazList } = await sb.from("markaz").select("id, name").in("id", markazIds);
  const markazById = new Map((markazList || []).map((m: any) => [m.id, m]));
  const { data: products } = await sb.from("products").select("id, product_name, unit_name");
  const unitByProduct = new Map((products || []).map((p: any) => [p.id, p.unit_name || ""]));

  const setRows = (ids: string[], patch: Record<string, unknown>) =>
    sb.from("aeo_report_queue").update(patch).in("id", ids);

  const summary = { sent: 0, no_recipient: 0, retry: 0, failed: 0 };

  for (const markazId of markazIds) {
    const rows = claimed.filter((r: any) => schoolById.get(r.school_id)?.markaz_id === markazId);
    const ids = rows.map((r: any) => r.id);
    const markaz = markazById.get(markazId);
    try {
      // Recipients: whoever holds this markaz as home or extra charge (same convention as the
      // app's AEO directory), active, with a real report email.
      const { data: people } = await sb.from("profiles")
        .select("full_name, report_email")
        .eq("active", true).in("role", ["aeo", "tr", "admin"]).not("report_email", "is", null)
        .or(`markaz_id.eq.${markazId},extra_markaz_ids.cs.{${markazId}}`);
      const seen = new Set<string>();
      const to = (people || []).filter((p: any) => {
        const e = String(p.report_email || "").trim().toLowerCase();
        if (!e || seen.has(e)) return false;
        seen.add(e); return true;
      }).map((p: any) => ({ email: String(p.report_email).trim(), name: p.full_name || undefined }));

      if (!to.length) {
        await setRows(ids, { status: "no_recipient", last_error: "No active AEO with a report email for this markaz" });
        summary.no_recipient += ids.length;
        continue;
      }

      // Build the per-school tables, one fn_period_report call per date.
      const dates = [...new Set(rows.map((r: any) => r.report_date))];
      const blocks: SchoolBlock[] = [];
      for (const date of dates) {
        const sIds = rows.filter((r: any) => r.report_date === date).map((r: any) => r.school_id);
        const { data: rep, error: repErr } = await sb.rpc("fn_period_report", { p_school_ids: sIds, p_from: date, p_to: date });
        if (repErr) throw repErr;
        for (const sid of sIds) {
          const s = schoolById.get(sid);
          const lines: Line[] = (rep || []).filter((r: any) => r.school_id === sid).map((r: any) => ({
            product: r.product_name,
            unit: unitByProduct.get(r.product_id) || "",
            opening: Number(r.opening),
            consumed: Number(r.consumed),
            remaining: Number(r.remaining_after_rationalization),
          })).sort((a: Line, b: Line) =>
            (a.product.toLowerCase().includes("milk") ? 0 : 1) - (b.product.toLowerCase().includes("milk") ? 0 : 1));
          blocks.push({ school: s.school_name, emis: s.emis_code, date: date as string, lines });
        }
      }
      blocks.sort((a, b) => a.date.localeCompare(b.date) || a.school.localeCompare(b.school));

      const email = renderEmail(markaz?.name || "your markaz", blocks);
      await sendBrevo(to, `SMP Consumption Report - ${markaz?.name || "Markaz"} (${email.range})`, email.html, email.text);
      await setRows(ids, { status: "sent", sent_at: new Date().toISOString(), sent_to: to.map((t) => t.email), last_error: null });
      summary.sent += ids.length;
    } catch (e) {
      const msg = String((e as any)?.message || e).slice(0, 500);
      // Count this attempt per row. Under the limit -> back to pending with a fresh debounce
      // window (retried automatically); at the limit -> parked as 'error' for an admin to see.
      for (const r of rows as any[]) {
        const attempts = (r.attempts ?? 0) + 1;
        if (attempts >= MAX_ATTEMPTS) {
          await sb.from("aeo_report_queue").update({ status: "error", attempts, last_error: msg }).eq("id", r.id);
          summary.failed++;
        } else {
          await sb.from("aeo_report_queue")
            .update({ status: "pending", attempts, last_error: msg, last_changed_at: new Date().toISOString() })
            .eq("id", r.id);
          summary.retry++;
        }
      }
    }
  }

  return json({ ok: true, processed: claimed.length, ...summary });
});
