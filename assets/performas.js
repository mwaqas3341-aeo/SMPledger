// Performas - ready-made official reporting sheets, prepared from the ledger and
// downloaded ONLY from Reports & Demand -> Performas.
//
// How to add another performa later:
//   1. Add an entry to SMP_PERFORMAS below (id, title, description, columns with their
//      data source, and a builder name).
//   2. Write its builder in SMP_PERFORMA_BUILDERS (turns collected data into sheets).
// The "Data mapping" card on the page is generated from `columns`, so the mapping the
// user sees is always the mapping the code uses.
//
// Everything here is split in two on purpose:
//   * perfCollect()      - talks to Supabase (RLS-scoped, same access rules as the page)
//   * perfAssemble()     - pure: rows in, sheet cells out (unit-testable without a browser)

const PERF_ZERO_DAYS = 0.9;       // "0 stock" = less than this many days left (same as the official summary)
const PERF_LEDGER_START = "2000-01-01";

const SMP_PERFORMAS = {
  daily_updates: {
    id: "daily_updates",
    title: "SMP Daily Updates",
    desc: "School-wise milk & biscuit stock position with days remaining, demand alert, empty packs, and a summary block.",
    builder: "daily_updates",
    scopes: ["markaz", "tehsil", "district"],
    columns: [
      { key: "sr",       header: "SrNo",                                      src: "Running number in the sheet", kind: "auto" },
      { key: "tw",       header: "Tehsil & Wing",                             src: "markaz.tehsil + schools.wing", kind: "data" },
      { key: "markaz",   header: "Markaz",                                    src: "markaz.name", kind: "data" },
      { key: "emis",     header: "EMIS-Code",                                 src: "schools.emis_code", kind: "data" },
      { key: "school",   header: "School",                                    src: "schools.school_name", kind: "data" },
      { key: "enrol",    header: "School Enrollement",                        src: "Live enrolment file (classes 6-12 excluded, same as Demand); falls back to schools.enrollment", kind: "data" },
      { key: "mPrev",    header: "Total Milk Packets received (previously)",  src: "Milk: everything received up to the day before the report date (receipts + transfers in - out + adjustments)", kind: "data" },
      { key: "mToday",   header: "Milk Packets received TODAY",               src: "Milk receipts entered for the report date", kind: "data" },
      { key: "bPrev",    header: "Total Biscuit Packets received (previously)", src: "Biscuits: same rule as milk", kind: "data" },
      { key: "bToday",   header: "Biscuit Packets received TODAY",            src: "Biscuit receipts entered for the report date", kind: "data" },
      { key: "mCons",    header: "Total Milk Packets Consumed",               src: "Sum of milk consumption from the start of the programme up to the report date", kind: "data" },
      { key: "bCons",    header: "Total Biscuit Packets Consumed",            src: "Sum of biscuit consumption up to the report date", kind: "data" },
      { key: "mRecv",    header: "Total Milk Packets received",               src: "= previous + today", kind: "formula" },
      { key: "bRecv",    header: "Total Biscuit Packets received",            src: "= previous + today", kind: "formula" },
      { key: "mRem",     header: "Remaining Stock Milk",                      src: "= total received - total consumed (equals the ledger balance)", kind: "formula" },
      { key: "bRem",     header: "Remaining Stock Biscuit",                   src: "= total received - total consumed", kind: "formula" },
      { key: "mDays",    header: "No of Days Remaining (Milk)",               src: "= remaining stock / enrolment (one pack per student per day)", kind: "formula" },
      { key: "bDays",    header: "No of Days Remaining (Biscuit)",            src: "= remaining stock / enrolment", kind: "formula" },
      { key: "mAlert",   header: "Demand Milk",                               src: "\"Alert-Demand\" when days remaining is below the alert level (default 4)", kind: "formula" },
      { key: "bAlert",   header: "Demand Biscuit",                            src: "same rule as milk", kind: "formula" },
      { key: "bEmpTot",  header: "total no of empty packs (Biscuits)",        src: "Not held in the system yet - left blank to fill in", kind: "manual" },
      { key: "bEmpLift", header: "Empty packs lifted by vendors (Biscuits)",  src: "Not held in the system yet - left blank to fill in", kind: "manual" },
      { key: "bEmpRem",  header: "Remaining empty packs in school (Biscuits)", src: "= total - lifted", kind: "formula" },
      { key: "mEmpTot",  header: "total no of empty packs (Milk)",            src: "Not held in the system yet - left blank to fill in", kind: "manual" },
      { key: "mEmpLift", header: "Empty packs lifted by vendors (Milk)",      src: "Not held in the system yet - left blank to fill in", kind: "manual" },
      { key: "mEmpRem",  header: "Remaining empty packs in school (Milk)",    src: "= total - lifted", kind: "formula" },
      { key: "remarks",  header: "Remarks",                                   src: "Added automatically, e.g. enrolment not found", kind: "auto" },
    ],
  },
};

/* ---------- small pure helpers ---------- */
function perfColLetter(i){ // 0 -> A
  let s = ""; i = i + 1;
  while(i > 0){ const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); }
  return s;
}
function perfDMY(iso){ const [y, m, d] = String(iso).slice(0, 10).split("-"); return `${d}-${m}-${y}`; }
function perfNum(x){ const n = Number(x); return Number.isFinite(n) ? n : 0; }
function perfSafeName(s){ return String(s || "").replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, ""); }

/* ---------- pure assembly ----------
   rows:  [{ tehsil, wing, markaz, emis, school, enrol (number|null), enrolSrc,
             m:{prev,today,cons}, b:{prev,today,cons} }]  - already sorted
   opts:  { district, scopeLabel, date, preparedBy, alertDays, groupBy: "markaz"|"tehsilwing" }
   returns { sheets:[{name, aoa, merges, cols}], model } - cell values are plain, or
   {t,f,v} objects when they are live Excel formulas with a cached result. */
function perfAssembleDaily(rows, opts){
  const alertDays = opts.alertDays ?? 4;
  const def = SMP_PERFORMAS.daily_updates;
  const headers = def.columns.map(c => c.header);
  const NC = headers.length;
  const L = {}; def.columns.forEach((c, i) => { L[c.key] = perfColLetter(i); });
  const num = (f, v) => ({ t: "n", f, v });
  const str = (f, v) => ({ t: "s", f, v });

  // computed model (also used for the on-screen preview)
  const model = rows.map((r, i) => {
    const e = r.enrol != null && r.enrol > 0 ? r.enrol : null;
    const mRecv = r.m.prev + r.m.today, bRecv = r.b.prev + r.b.today;
    const mRem = mRecv - r.m.cons, bRem = bRecv - r.b.cons;
    const mDays = e ? mRem / e : null, bDays = e ? bRem / e : null;
    const remarks = [];
    if(e == null) remarks.push("Enrolment not found");
    else if(r.enrolSrc === "system") remarks.push("Enrolment from system record");
    if(mRem < 0) remarks.push("Milk stock negative");
    if(bRem < 0) remarks.push("Biscuit stock negative");
    return { ...r, sr: i + 1, e, mRecv, bRecv, mRem, bRem, mDays, bDays, remarks: remarks.join("; ") };
  });

  function dataRowCells(x, xlRow, withEmpty){
    const q = L.mDays, r_ = L.bDays;
    const row = new Array(NC).fill(null);
    const set = (k, v) => { row[def.columns.findIndex(c => c.key === k)] = v; };
    set("sr", x.sr);
    set("tw", `${x.tehsil || ""} ${x.wing || ""}`.trim());
    set("markaz", x.markaz); set("emis", x.emis ? Number(x.emis) || x.emis : ""); set("school", x.school);
    set("enrol", x.e != null ? x.e : "");
    set("mPrev", x.m.prev); set("mToday", x.m.today); set("bPrev", x.b.prev); set("bToday", x.b.today);
    set("mCons", x.m.cons); set("bCons", x.b.cons);
    set("mRecv", num(`${L.mPrev}${xlRow}+${L.mToday}${xlRow}`, x.mRecv));
    set("bRecv", num(`${L.bPrev}${xlRow}+${L.bToday}${xlRow}`, x.bRecv));
    set("mRem", num(`${L.mRecv}${xlRow}-${L.mCons}${xlRow}`, x.mRem));
    set("bRem", num(`${L.bRecv}${xlRow}-${L.bCons}${xlRow}`, x.bRem));
    set("mDays", x.mDays == null ? str(`IFERROR(${L.mRem}${xlRow}/${L.enrol}${xlRow},"")`, "")
                                 : num(`IFERROR(${L.mRem}${xlRow}/${L.enrol}${xlRow},"")`, x.mDays));
    set("bDays", x.bDays == null ? str(`IFERROR(${L.bRem}${xlRow}/${L.enrol}${xlRow},"")`, "")
                                 : num(`IFERROR(${L.bRem}${xlRow}/${L.enrol}${xlRow},"")`, x.bDays));
    const alertV = d => d == null ? "Enrolment?" : (d < alertDays ? "Alert-Demand" : "NO");
    set("mAlert", str(`IF(${q}${xlRow}="","Enrolment?",IF(${q}${xlRow}<${alertDays},"Alert-Demand","NO"))`, alertV(x.mDays)));
    set("bAlert", str(`IF(${r_}${xlRow}="","Enrolment?",IF(${r_}${xlRow}<${alertDays},"Alert-Demand","NO"))`, alertV(x.bDays)));
    if(withEmpty){
      set("bEmpRem", num(`N(${L.bEmpTot}${xlRow})-N(${L.bEmpLift}${xlRow})`, 0));
      set("mEmpRem", num(`N(${L.mEmpTot}${xlRow})-N(${L.mEmpLift}${xlRow})`, 0));
    }
    set("remarks", x.remarks);
    return row;
  }

  const title = `CM Meal Program, District ${opts.district || ""} | ${opts.scopeLabel || ""} | Dated ${perfDMY(opts.date)} | Prepared by: ${opts.preparedBy || ""}`;
  const merges = [{ s: { r: 0, c: 0 }, e: { r: 0, c: NC - 1 } }];
  const colsW = [6, 20, 26, 11, 32, 11, 14, 12, 14, 12, 14, 14, 14, 14, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 26].map(w => ({ wch: w }));

  /* ---- main sheet ---- */
  const aoa = [];
  aoa.push([title]);
  aoa.push(headers);
  const first = 3; // Excel row of first data row
  model.forEach((x, i) => aoa.push(dataRowCells(x, first + i, true)));
  const last = first + model.length - 1;
  const totXl = last + 1;
  // total row
  const sumCols = ["enrol", "mPrev", "mToday", "bPrev", "bToday", "mCons", "bCons", "mRecv", "bRecv", "mRem", "bRem", "bEmpTot", "bEmpLift", "bEmpRem", "mEmpTot", "mEmpLift", "mEmpRem"];
  const totVal = {
    enrol: model.reduce((a, x) => a + (x.e || 0), 0),
    mPrev: model.reduce((a, x) => a + x.m.prev, 0), mToday: model.reduce((a, x) => a + x.m.today, 0),
    bPrev: model.reduce((a, x) => a + x.b.prev, 0), bToday: model.reduce((a, x) => a + x.b.today, 0),
    mCons: model.reduce((a, x) => a + x.m.cons, 0), bCons: model.reduce((a, x) => a + x.b.cons, 0),
    mRecv: model.reduce((a, x) => a + x.mRecv, 0), bRecv: model.reduce((a, x) => a + x.bRecv, 0),
    mRem: model.reduce((a, x) => a + x.mRem, 0), bRem: model.reduce((a, x) => a + x.bRem, 0),
    bEmpTot: 0, bEmpLift: 0, bEmpRem: 0, mEmpTot: 0, mEmpLift: 0, mEmpRem: 0,
  };
  const tot = new Array(NC).fill(null);
  tot[def.columns.findIndex(c => c.key === "school")] = "Total";
  sumCols.forEach(k => { tot[def.columns.findIndex(c => c.key === k)] = num(`SUM(${L[k]}${first}:${L[k]}${last})`, totVal[k]); });
  aoa.push(tot);
  aoa.push([]);
  aoa.push([`Milk and Biscuit "Demand Alert" is generated when stock remaining is less than ${alertDays} days.`]);
  aoa.push([]);

  /* ---- summary block ---- */
  const groups = [];
  model.forEach((x, i) => {
    const key = opts.groupBy === "tehsilwing" ? `${x.tehsil} ${x.wing || ""}`.trim() : x.markaz;
    const g = groups[groups.length - 1];
    if(g && g.key === key){ g.to = i; } else { groups.push({ key, from: i, to: i }); }
  });
  const sumTitleRow = aoa.length + 1;
  aoa.push([null, `Summary Dated ${perfDMY(opts.date)}`]);
  merges.push({ s: { r: sumTitleRow - 1, c: 1 }, e: { r: sumTitleRow - 1, c: 9 } });
  aoa.push([null, "No", opts.groupBy === "tehsilwing" ? "Tehsil Wing" : "Markaz", "T. Milk Rcvd", "Remaining Stock of Milk", "Total Biskt Rcv", "R. Stock Biskt", "No. Schl 0 Milk", "No. Schl 0 Biskt", "Enrolment"]);
  const sFirst = aoa.length + 1;
  const sumRows = groups.map((g, gi) => {
    const a = first + g.from, b = first + g.to, sl = model.slice(g.from, g.to + 1);
    const v = {
      mRecv: sl.reduce((s, x) => s + x.mRecv, 0), mRem: sl.reduce((s, x) => s + x.mRem, 0),
      bRecv: sl.reduce((s, x) => s + x.bRecv, 0), bRem: sl.reduce((s, x) => s + x.bRem, 0),
      m0: sl.filter(x => x.mDays != null && x.mDays < PERF_ZERO_DAYS).length,
      b0: sl.filter(x => x.bDays != null && x.bDays < PERF_ZERO_DAYS).length,
      enrol: sl.reduce((s, x) => s + (x.e || 0), 0),
    };
    aoa.push([null, gi + 1, g.key,
      num(`SUM(${L.mRecv}${a}:${L.mRecv}${b})`, v.mRecv), num(`SUM(${L.mRem}${a}:${L.mRem}${b})`, v.mRem),
      num(`SUM(${L.bRecv}${a}:${L.bRecv}${b})`, v.bRecv), num(`SUM(${L.bRem}${a}:${L.bRem}${b})`, v.bRem),
      num(`COUNTIF(${L.mDays}${a}:${L.mDays}${b},"<${PERF_ZERO_DAYS}")`, v.m0),
      num(`COUNTIF(${L.bDays}${a}:${L.bDays}${b},"<${PERF_ZERO_DAYS}")`, v.b0),
      num(`SUM(${L.enrol}${a}:${L.enrol}${b})`, v.enrol)]);
    return v;
  });
  const sLast = aoa.length;
  const T = k => sumRows.reduce((s, v) => s + v[k], 0);
  const colSum = c => `SUM(${c}${sFirst}:${c}${sLast})`;
  aoa.push([null, null, "Total", num(colSum("D"), T("mRecv")), num(colSum("E"), T("mRem")), num(colSum("F"), T("bRecv")), num(colSum("G"), T("bRem")),
    num(colSum("H"), T("m0")), num(colSum("I"), T("b0")), num(colSum("J"), T("enrol"))]);
  aoa.push([]);
  // side block (same figures as the official sheet's right-hand block)
  const side = [
    ["Total Milk Packets received", totVal.mRecv, `${L.mRecv}${totXl}`],
    ["Remaining Stock Milk", totVal.mRem, `${L.mRem}${totXl}`],
    ["Total Biscuit Packets received", totVal.bRecv, `${L.bRecv}${totXl}`],
    ["Remaining Stock Biscuit", totVal.bRem, `${L.bRem}${totXl}`],
    ["Current Enrollment", totVal.enrol, `${L.enrol}${totXl}`],
    ["total no of empty packs (Biscuits)", 0, `${L.bEmpTot}${totXl}`],
    ["Empty packs lifted by vendors (Biscuits)", 0, `${L.bEmpLift}${totXl}`],
    ["Remaining empty packs in school (Biscuits)", 0, `${L.bEmpRem}${totXl}`],
    ["total no of empty packs (Milk)", 0, `${L.mEmpTot}${totXl}`],
    ["Empty packs lifted by vendors (Milk)", 0, `${L.mEmpLift}${totXl}`],
    ["Remaining empty packs in school (Milk)", 0, `${L.mEmpRem}${totXl}`],
  ];
  side.forEach(([label, v, ref]) => aoa.push([null, null, label, num(ref, v)]));

  const sheets = [{ name: "Performa", aoa, merges, cols: colsW, headerRow: 2 }];

  /* ---- zero-stock lists (hidden sheets in the official file; shown here) ---- */
  const zeroSheet = (name, label, test) => {
    const sel = model.filter(test);
    const a2 = [[`${String(sel.length).padStart(2, "0")} Schools list having 0 ${label} Stock`], headers.slice(0, 20)];
    sel.forEach((x, i) => {
      const cells = dataRowCells({ ...x, sr: i + 1 }, 3 + i, false).slice(0, 20);
      a2.push(cells);
    });
    return { name, aoa: a2, merges: [{ s: { r: 0, c: 0 }, e: { r: 0, c: 19 } }], cols: colsW.slice(0, 20), headerRow: 2 };
  };
  sheets.push(zeroSheet("0 Milk stock", "Milk", x => x.mDays != null && x.mDays < PERF_ZERO_DAYS));
  sheets.push(zeroSheet("0 Biscuit stock", "Biscuit", x => x.bDays != null && x.bDays < PERF_ZERO_DAYS));

  return { sheets, model, summary: groups.map((g, i) => ({ key: g.key, ...sumRows[i] })), totals: totVal, title };
}

const SMP_PERFORMA_BUILDERS = {
  daily_updates: perfAssembleDaily,
};

/* ---------- Excel writer (SheetJS) ---------- */
function perfToWorkbook(sheets){
  const wb = XLSX.utils.book_new();
  sheets.forEach(sh => {
    const ws = XLSX.utils.aoa_to_sheet(sh.aoa.map(row => row.map(c => (c && typeof c === "object") ? { t: c.t, f: c.f, v: c.v } : c)));
    ws["!merges"] = sh.merges;
    ws["!cols"] = sh.cols;
    XLSX.utils.book_append_sheet(wb, ws, sh.name);
  });
  return wb;
}

/* ---------- data collection (browser only) ---------- */
async function perfCollect(ctx){
  // ctx: { scope: "markaz"|"tehsil"|"district", markazId, tehsil, wing, date }
  const [milk, biscuit] = cache.products;
  if(!milk || !biscuit) throw new Error("Products are not loaded");

  const mkQuery = () => {
    let q = sb.from("schools").select("id,school_name,emis_code,markaz_id,wing,enrollment,markaz!inner(name,tehsil)").eq("active", true);
    q = scopeSchoolsQuery(q);
    if(ctx.scope === "markaz") q = q.eq("markaz_id", ctx.markazId);
    else if(ctx.scope === "tehsil") q = q.eq("markaz.tehsil", ctx.tehsil);
    if(ctx.wing) q = q.eq("wing", ctx.wing);
    return q.order("id");
  };
  const { data: schools, error } = await smpFetchAll(mkQuery);
  if(error) throw new Error(error.message);
  if(!schools?.length) throw new Error("No schools found for this selection");
  schools.sort((a, b) => (a.markaz?.tehsil || "").localeCompare(b.markaz?.tehsil || "") || (a.wing || "").localeCompare(b.wing || "")
    || (a.markaz?.name || "").localeCompare(b.markaz?.name || "") || (a.emis_code || "").localeCompare(b.emis_code || ""));
  const ids = schools.map(s => s.id);

  // Enrolment: live file first (same rule as Demand), system record as fallback.
  const EXCL = new Set(["6", "7", "8", "9", "10", "11", "12"]);
  const live = {}; let liveOk = false, liveDate = null;
  try{
    const res = await fetch(ENROLMENT_URL, { cache: "no-store" });
    if(!res.ok) throw new Error("HTTP " + res.status);
    const d = await res.json();
    (d.schools || []).forEach(s => {
      live[s.emis_code] = (s.grades || []).filter(g => !EXCL.has(String(g.grade_name).trim()))
        .reduce((sum, g) => sum + perfNum(g.male_students) + perfNum(g.female_students), 0);
    });
    liveOk = true; liveDate = d.scraped_at || null;
  }catch(e){ /* fall back to system record below */ }

  // Stock: two ledger windows. A = the report date alone (received today), B = everything up to it.
  const rpc = (from, to) => smpFetchAll(() => sb.rpc("fn_period_report", { p_school_ids: ids, p_from: from, p_to: to }).order("school_id").order("product_id"));
  const [A, B] = await Promise.all([rpc(ctx.date, ctx.date), rpc(PERF_LEDGER_START, ctx.date)]);
  if(A.error) throw new Error(A.error.message);
  if(B.error) throw new Error(B.error.message);
  const idx = (res) => { const o = {}; (res.data || []).forEach(r => { (o[r.school_id] = o[r.school_id] || {})[r.product_id] = r; }); return o; };
  const a = idx(A), b = idx(B);

  const prod = (sid, p) => {
    const ra = (a[sid] || {})[p.id] || {}, rb = (b[sid] || {})[p.id] || {};
    const cons = perfNum(rb.consumed);
    const remaining = perfNum(rb.remaining_after_rationalization);       // ledger balance on the report date
    const total = remaining + cons;                                       // everything that has come in, net of transfers/adjustments
    const today = perfNum(ra.received) + perfNum(ra.received_from) - perfNum(ra.sent_out);
    return { prev: total - today, today, cons };
  };

  const rows = schools.map(s => {
    let enrol = null, enrolSrc = null;
    if(liveOk && live[s.emis_code] != null && live[s.emis_code] > 0){ enrol = live[s.emis_code]; enrolSrc = "live"; }
    else if(s.enrollment != null && Number(s.enrollment) > 0){ enrol = Number(s.enrollment); enrolSrc = "system"; }
    return {
      tehsil: s.markaz?.tehsil, wing: s.wing, markaz: s.markaz?.name, emis: s.emis_code, school: s.school_name,
      enrol, enrolSrc, m: prod(s.id, milk), b: prod(s.id, biscuit),
    };
  });
  return { rows, liveOk, liveDate };
}

/* ---------- page section ---------- */
function perfScopeOptions(){
  // Never wider than the access the person already has.
  const role = currentProfile.role;
  const isAdmin = ["admin", "super_admin"].includes(role);
  let ms = cache.markaz;
  if(role === "aeo") ms = ms.filter(m => myMarkazIds().includes(m.id));
  else if(role === "tr" && currentProfile.tehsil) ms = ms.filter(m => m.tehsil === currentProfile.tehsil);
  const tehsils = [...new Set(ms.map(m => m.tehsil))].filter(Boolean).sort();
  return { isAdmin, markaz: ms, tehsils, canTehsil: role !== "aeo" || tehsils.length > 0 };
}

function renderPerformasSection(){
  const content = document.getElementById("repSectionContent");
  if(currentProfile.role === "school_user"){
    content.innerHTML = `<div class="card"><h3>Performas</h3><p class="sub">Performas are prepared at markaz level or above. Please ask your AEO.</p></div>`;
    return;
  }
  const opt = perfScopeOptions();
  const def = SMP_PERFORMAS.daily_updates;
  const markazOpts = opt.markaz.map(m => `<option value="${esc(m.id)}">${esc(m.name)} (${esc(m.tehsil)})</option>`).join("");
  const tehsilOpts = opt.tehsils.map(t => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
  const canWide = opt.isAdmin || currentProfile.role === "tr";

  content.innerHTML = `
    <div class="card">
      <h3>Performas</h3>
      <p class="sub">Official reporting sheets prepared from the ledger. Choose the performa, the area and the date, preview it, then download the Excel file. Performas are prepared and downloaded only from here.</p>
      <form id="perfForm" class="form-row">
        <div><label>Performa</label>
          <select name="performa" id="perfId"><option value="daily_updates">${esc(def.title)}</option></select></div>
        <div><label>Level</label>
          <select name="scope" id="perfScope">
            <option value="markaz">Markaz</option>
            ${canWide ? `<option value="tehsil">Whole tehsil</option>` : ""}
            ${opt.isAdmin ? `<option value="district">Whole district</option>` : ""}
          </select></div>
        <div id="perfTehsilBox"><label>Tehsil</label><select name="tehsil" id="perfTehsil"></select></div>
        <div id="perfWingBox"><label>Wing</label>
          <select name="wing" id="perfWing"><option value="">All</option>${WING_OPTIONS.map(w => `<option value="${esc(w)}">${esc(w)}</option>`).join("")}</select></div>
        <div id="perfMarkazBox"><label>Markaz</label><select name="markaz" id="perfMarkaz"></select></div>
        <div><label>Report date</label><input type="date" name="date" value="${todayStr()}" max="${todayStr()}" required/></div>
        <div><label>Alert when days left below</label><input type="number" name="alert" value="4" min="0.5" step="0.5" style="width:90px;"/></div>
        <div style="align-self:end;"><button class="btn-primary" type="submit" id="perfGo">Prepare performa</button></div>
      </form>
      <div id="perfStatus"></div>
    </div>
    <div class="card" id="perfResult" style="display:none;">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin-bottom:10px;">
        <h3 style="margin:0;" id="perfResultTitle">Preview</h3>
        <button class="btn-export" id="perfDownload" type="button">Download Excel</button>
      </div>
      <div id="perfNotes"></div>
      <div class="table-wrap"><table id="perfTable" style="font-size:11.5px;"><thead></thead><tbody></tbody></table></div>
      <h4 style="margin:16px 0 6px;">Summary</h4>
      <div class="table-wrap"><table id="perfSummary" style="font-size:12px;"><thead></thead><tbody></tbody></table></div>
    </div>
    <div class="card">
      <h3>Data mapping - ${esc(def.title)}</h3>
      <p class="sub">Where each column comes from. This list is what the download is built from.</p>
      <div class="table-wrap"><table style="font-size:12px;">
        <thead><tr><th>Column</th><th>Type</th><th>Source in the system</th></tr></thead>
        <tbody>${def.columns.map(c => `<tr><td>${esc(c.header)}</td><td>${c.kind === "data" ? "From system" : c.kind === "formula" ? "Formula" : c.kind === "manual" ? "Fill in" : "Automatic"}</td><td style="white-space:normal;">${esc(c.src)}</td></tr>`).join("")}</tbody>
      </table></div>
    </div>`;

  const form = document.getElementById("perfForm");
  const scopeSel = document.getElementById("perfScope");
  // Which wings each markaz actually has (markaz itself carries no wing), read once.
  const wingsByMarkaz = {};
  const fillMarkaz = () => {
    const t = document.getElementById("perfTehsil").value, w = document.getElementById("perfWing").value;
    const list = opt.markaz.filter(m => (!t || m.tehsil === t) && (!w || (wingsByMarkaz[m.id] || new Set([w])).has(w)));
    const sel = document.getElementById("perfMarkaz"), keep = sel.value;
    sel.innerHTML = list.length ? list.map(m => `<option value="${esc(m.id)}">${esc(m.name)}</option>`).join("") : `<option value="">No markaz for this filter</option>`;
    if(list.some(m => m.id === keep)) sel.value = keep;
  };
  const syncScope = () => {
    const s = scopeSel.value, ts = document.getElementById("perfTehsil");
    document.getElementById("perfMarkazBox").style.display = s === "markaz" ? "" : "none";
    document.getElementById("perfTehsilBox").style.display = s === "district" ? "none" : "";
    // Markaz level: tehsil is optional (just narrows the list). Tehsil level: one must be chosen.
    const keep = ts.value;
    ts.innerHTML = (s === "markaz" && opt.tehsils.length > 1 ? `<option value="">All</option>` : "") + tehsilOpts;
    if([...ts.options].some(o => o.value === keep)) ts.value = keep;
    fillMarkaz();
  };
  scopeSel.addEventListener("change", syncScope);
  document.getElementById("perfTehsil").addEventListener("change", fillMarkaz);
  document.getElementById("perfWing").addEventListener("change", fillMarkaz);
  syncScope();
  (async () => {
    try{
      const { data } = await smpFetchAll(() => scopeSchoolsQuery(sb.from("schools").select("id,markaz_id,wing,markaz!inner(tehsil)").eq("active", true)).order("id"));
      (data || []).forEach(r => { if(r.wing) (wingsByMarkaz[r.markaz_id] = wingsByMarkaz[r.markaz_id] || new Set()).add(r.wing); });
      fillMarkaz();
    }catch(e){ /* filter simply shows every markaz */ }
  })();
  if(!opt.markaz.length) document.getElementById("perfStatus").innerHTML = `<p class="err">No markaz is assigned to your account.</p>`;

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    const scope = fd.get("scope");
    const ctx = { scope, markazId: fd.get("markaz"), tehsil: scope === "tehsil" ? fd.get("tehsil") : null, wing: fd.get("wing"), date: fd.get("date") };
    const alertDays = Number(fd.get("alert")) || 4;
    if(scope === "markaz" && !ctx.markazId){ st0(); return; }
    function st0(){ document.getElementById("perfStatus").innerHTML = `<p class="err">Select a markaz first.</p>`; }
    const btn = document.getElementById("perfGo"), st = document.getElementById("perfStatus");
    btn.disabled = true; btn.textContent = "Preparing…";
    st.innerHTML = `<p style="color:var(--ink-soft); font-size:12.5px; margin-top:10px;">Reading the ledger…</p>`;
    try{
      const data = await perfCollect(ctx);
      const mk = opt.markaz.find(m => m.id === ctx.markazId);
      const scopeLabel = scope === "markaz" ? `Markaz ${mk?.name || ""}${ctx.wing ? " " + ctx.wing : ""}` : scope === "tehsil" ? `Tehsil ${ctx.tehsil}${ctx.wing ? " " + ctx.wing : ""}` : `All tehsils${ctx.wing ? " " + ctx.wing : ""}`;
      const district = (opt.markaz[0]?.district || "Layyah");
      const out = SMP_PERFORMA_BUILDERS[def.builder](data.rows, {
        district, scopeLabel, date: ctx.date, alertDays,
        preparedBy: currentProfile.full_name || currentUser.email,
        groupBy: scope === "district" ? "tehsilwing" : "markaz",
      });
      renderPerfPreview(out, data, ctx, alertDays);
      document.getElementById("perfDownload").onclick = () => {
        const wb = perfToWorkbook(out.sheets);
        const slug = scope === "markaz" ? perfSafeName(mk?.name) : scope === "tehsil" ? perfSafeName(ctx.tehsil) : "district";
        XLSX.writeFile(wb, `SMP_Daily_Updates_${slug}_${ctx.date}.xlsx`);
      };
      st.innerHTML = "";
    }catch(err){
      st.innerHTML = `<p class="err">${esc(err.message)}</p>`;
    }finally{
      btn.disabled = false; btn.textContent = "Prepare performa";
    }
  });
}

function renderPerfPreview(out, data, ctx, alertDays){
  const def = SMP_PERFORMAS.daily_updates;
  document.getElementById("perfResult").style.display = "";
  document.getElementById("perfResultTitle").textContent = out.title;
  const missing = out.model.filter(x => x.e == null).length;
  const fromSystem = out.model.filter(x => x.enrolSrc === "system").length;
  document.getElementById("perfNotes").innerHTML = `<p style="color:var(--ink-soft); font-size:12.5px;">
    ${out.model.length} schools. Consumption and receipts are counted up to and including ${esc(perfDMY(ctx.date))}.
    ${data.liveOk ? `Enrolment read live just now${data.liveDate ? " (source updated " + esc(fmtDMY(data.liveDate)) + ")" : ""}.` : `<b>Live enrolment file could not be read</b> - system enrolment records were used.`}
    ${fromSystem ? `${fromSystem} school(s) use the system enrolment record.` : ""}
    ${missing ? `<b>${missing} school(s) have no enrolment</b>, so days remaining cannot be worked out for them (marked "Enrolment?").` : ""}
    Empty-pack columns are not held in the system yet; they are blank in the file for filling in.</p>`;
  const cols = def.columns.filter(c => !["bEmpTot", "bEmpLift", "bEmpRem", "mEmpTot", "mEmpLift", "mEmpRem"].includes(c.key));
  document.querySelector("#perfTable thead").innerHTML = `<tr>${cols.map(c => `<th style="white-space:normal;">${esc(c.header)}</th>`).join("")}</tr>`;
  const d1 = v => v == null ? "—" : (Math.round(v * 100) / 100).toLocaleString();
  document.querySelector("#perfTable tbody").innerHTML = out.model.map(x => {
    const v = { sr: x.sr, tw: `${x.tehsil || ""} ${x.wing || ""}`.trim(), markaz: x.markaz, emis: x.emis, school: x.school, enrol: x.e ?? "—",
      mPrev: x.m.prev, mToday: x.m.today, bPrev: x.b.prev, bToday: x.b.today, mCons: x.m.cons, bCons: x.b.cons,
      mRecv: x.mRecv, bRecv: x.bRecv, mRem: x.mRem, bRem: x.bRem, mDays: d1(x.mDays), bDays: d1(x.bDays),
      mAlert: x.mDays == null ? "Enrolment?" : (x.mDays < alertDays ? "Alert-Demand" : "NO"),
      bAlert: x.bDays == null ? "Enrolment?" : (x.bDays < alertDays ? "Alert-Demand" : "NO"), remarks: x.remarks };
    return `<tr>${cols.map(c => {
      const val = v[c.key];
      const alert = (c.key === "mAlert" || c.key === "bAlert") && val === "Alert-Demand";
      return `<td style="${alert ? "color:#b3261e;font-weight:700;" : ""}${["markaz", "school", "remarks"].includes(c.key) ? "white-space:normal;" : ""}">${typeof val === "number" ? val.toLocaleString() : esc(val)}</td>`;
    }).join("")}</tr>`;
  }).join("");
  document.querySelector("#perfSummary thead").innerHTML = `<tr><th>Area</th><th>Milk received</th><th>Milk remaining</th><th>Biscuit received</th><th>Biscuit remaining</th><th>Schools 0 milk</th><th>Schools 0 biscuit</th><th>Enrolment</th></tr>`;
  const s = out.summary;
  const tot = k => s.reduce((a, r) => a + r[k], 0);
  document.querySelector("#perfSummary tbody").innerHTML = s.map(r => `<tr><td>${esc(r.key)}</td><td>${r.mRecv.toLocaleString()}</td><td>${r.mRem.toLocaleString()}</td><td>${r.bRecv.toLocaleString()}</td><td>${r.bRem.toLocaleString()}</td><td>${r.m0}</td><td>${r.b0}</td><td>${r.enrol.toLocaleString()}</td></tr>`).join("")
    + `<tr class="total-row"><td>Total</td><td>${tot("mRecv").toLocaleString()}</td><td>${tot("mRem").toLocaleString()}</td><td>${tot("bRecv").toLocaleString()}</td><td>${tot("bRem").toLocaleString()}</td><td>${tot("m0")}</td><td>${tot("b0")}</td><td>${tot("enrol").toLocaleString()}</td></tr>`;
}

if(typeof module !== "undefined") module.exports = { perfAssembleDaily, perfColLetter, SMP_PERFORMAS };
