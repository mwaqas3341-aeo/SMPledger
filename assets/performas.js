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
  invoice_corrections: {
    id: "invoice_corrections",
    title: "Correction Request - Head teacher inventory entries",
    desc: "Head-teacher inventory entries on SMP whose challan number or quantity differs from the company invoice, with old value, new value and an automatic reason.",
    builder: "invoice_corrections",
    scopes: ["markaz", "tehsil", "district"],
    columns: [
      { key: "emis",    header: "Emis Code",       src: "schools.emis_code", kind: "data" },
      { key: "school",  header: "School Name",     src: "schools.school_name", kind: "data" },
      { key: "cat",     header: "Category (inventory received, pack lifted, consumption or other)", src: "Fixed: \"Inventory Received\" (only category held in the system for this performa)", kind: "auto" },
      { key: "tw",      header: "tehsil and wing", src: "markaz.tehsil + schools.wing", kind: "data" },
      { key: "type",    header: "Type (milk, biscuit)", src: "products.product_name of the receipt", kind: "data" },
      { key: "challan", header: "Challan Number",  src: "Correct invoice number (the company invoice)", kind: "data" },
      { key: "old",     header: "Old Value",       src: "What the head teacher entered on SMP - the challan number, or the quantity on a separate line when the quantity is wrong", kind: "data" },
      { key: "new",     header: "New Value",       src: "What the company invoice says (invoice number, or quantity)", kind: "data" },
      { key: "reason",  header: "Reason",          src: "Worked out automatically: for a challan number - letter O for 0, missing/extra character, wrong digit; for a quantity - the amount entered vs the invoice and the shortfall or excess", kind: "auto" },
      { key: "remarks", header: "Remarks if any",  src: "Blank - fill in", kind: "manual" },
      { key: "comments",header: "Comments",        src: "Blank - fill in", kind: "manual" },
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
   opts:  { district, scopeLabel, date, preparedBy, alertMilk, alertBiscuit, groupBy: "markaz"|"tehsilwing" }
   returns { sheets:[{name, aoa, merges, cols}], model } - cell values are plain, or
   {t,f,v} objects when they are live Excel formulas with a cached result. */
function perfAssembleDaily(rows, opts){
  const alertM = opts.alertMilk ?? opts.alertDays ?? 4, alertB = opts.alertBiscuit ?? opts.alertDays ?? 4;
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
    const alertV = (d, lim) => d == null ? "Enrolment?" : (d < lim ? "Alert-Demand" : "NO");
    set("mAlert", str(`IF(${q}${xlRow}="","Enrolment?",IF(${q}${xlRow}<${alertM},"Alert-Demand","NO"))`, alertV(x.mDays, alertM)));
    set("bAlert", str(`IF(${r_}${xlRow}="","Enrolment?",IF(${r_}${xlRow}<${alertB},"Alert-Demand","NO"))`, alertV(x.bDays, alertB)));
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
  aoa.push([`"Demand Alert" is generated when Milk stock remaining is less than ${alertM} days and Biscuit stock remaining is less than ${alertB} days.`]);
  aoa.push([]);

  /* ---- summary: its own sheet in the same workbook ---- */
  const groups = [];
  model.forEach((x, i) => {
    const key = opts.groupBy === "tehsilwing" ? `${x.tehsil} ${x.wing || ""}`.trim() : x.markaz;
    const g = groups[groups.length - 1];
    if(g && g.key === key){ g.to = i; } else { groups.push({ key, from: i, to: i }); }
  });
  const P = "Performa!";
  const sa = [];
  const smerges = [{ s: { r: 0, c: 0 }, e: { r: 0, c: 8 } }];
  sa.push([`Summary Dated ${perfDMY(opts.date)} | ${opts.scopeLabel || ""}`]);
  sa.push(["No", opts.groupBy === "tehsilwing" ? "Tehsil Wing" : "Markaz", "T. Milk Rcvd", "Remaining Stock of Milk", "Total Biskt Rcv", "R. Stock Biskt", "No. Schl 0 Milk", "No. Schl 0 Biskt", "Enrolment"]);
  const sFirst = 3;
  const sumRows = groups.map((g, gi) => {
    const a = first + g.from, b = first + g.to, sl = model.slice(g.from, g.to + 1);
    const v = {
      mRecv: sl.reduce((s, x) => s + x.mRecv, 0), mRem: sl.reduce((s, x) => s + x.mRem, 0),
      bRecv: sl.reduce((s, x) => s + x.bRecv, 0), bRem: sl.reduce((s, x) => s + x.bRem, 0),
      m0: sl.filter(x => x.mDays != null && x.mDays < PERF_ZERO_DAYS).length,
      b0: sl.filter(x => x.bDays != null && x.bDays < PERF_ZERO_DAYS).length,
      enrol: sl.reduce((s, x) => s + (x.e || 0), 0),
    };
    sa.push([gi + 1, g.key,
      num(`SUM(${P}${L.mRecv}${a}:${L.mRecv}${b})`, v.mRecv), num(`SUM(${P}${L.mRem}${a}:${L.mRem}${b})`, v.mRem),
      num(`SUM(${P}${L.bRecv}${a}:${L.bRecv}${b})`, v.bRecv), num(`SUM(${P}${L.bRem}${a}:${L.bRem}${b})`, v.bRem),
      num(`COUNTIF(${P}${L.mDays}${a}:${L.mDays}${b},"<${PERF_ZERO_DAYS}")`, v.m0),
      num(`COUNTIF(${P}${L.bDays}${a}:${L.bDays}${b},"<${PERF_ZERO_DAYS}")`, v.b0),
      num(`SUM(${P}${L.enrol}${a}:${L.enrol}${b})`, v.enrol)]);
    return v;
  });
  const sLast = sa.length;
  const T = k => sumRows.reduce((s, v) => s + v[k], 0);
  const colSum = c => `SUM(${c}${sFirst}:${c}${sLast})`;
  sa.push([null, "Total", num(colSum("C"), T("mRecv")), num(colSum("D"), T("mRem")), num(colSum("E"), T("bRecv")), num(colSum("F"), T("bRem")),
    num(colSum("G"), T("m0")), num(colSum("H"), T("b0")), num(colSum("I"), T("enrol"))]);
  sa.push([]);
  const side = [
    ["Total Milk Packets received", totVal.mRecv, "mRecv"],
    ["Remaining Stock Milk", totVal.mRem, "mRem"],
    ["Total Biscuit Packets received", totVal.bRecv, "bRecv"],
    ["Remaining Stock Biscuit", totVal.bRem, "bRem"],
    ["Current Enrollment", totVal.enrol, "enrol"],
    ["total no of empty packs (Biscuits)", 0, "bEmpTot"],
    ["Empty packs lifted by vendors (Biscuits)", 0, "bEmpLift"],
    ["Remaining empty packs in school (Biscuits)", 0, "bEmpRem"],
    ["total no of empty packs (Milk)", 0, "mEmpTot"],
    ["Empty packs lifted by vendors (Milk)", 0, "mEmpLift"],
    ["Remaining empty packs in school (Milk)", 0, "mEmpRem"],
  ];
  side.forEach(([label, v, k]) => sa.push([null, label, num(`${P}${L[k]}${totXl}`, v)]));

  const sheets = [
    { name: "Performa", aoa, merges, cols: colsW, headerRow: 2 },
    { name: "Summary", aoa: sa, merges: smerges, cols: [6, 40, 14, 18, 14, 14, 14, 14, 12].map(w => ({ wch: w })), headerRow: 2 },
  ];

  return { sheets, model, summary: groups.map((g, i) => ({ key: g.key, ...sumRows[i] })), totals: totVal, title };
}

/* ---- Correction request performa ---- */
// Explains how the head teacher's value differs from the right one, e.g.
// "Head teacher entered letter O instead of 0; missed '5'".
function perfInvoiceReason(oldV, newV){
  const o = String(oldV || "").replace(/\s+/g, ""), n = String(newV || "").replace(/\s+/g, "");
  if(!o) return "Head teacher did not enter the challan number";
  if(o === n) return "";
  if(o.toUpperCase() === n.toUpperCase()) return "Head teacher entered the number in different letter case";
  if(o.length > n.length && o.startsWith(n)) return `Head teacher entered an extra '${o.slice(n.length)}' at the end`;
  if(n.length > o.length && n.startsWith(o)) return `Head teacher missed '${n.slice(o.length)}' at the end`;
  // edit script by dynamic programming; letter O typed for zero costs less than a plain substitution
  const m = o.length, k = n.length, INF = 1e9;
  const D = Array.from({ length: m + 1 }, () => new Array(k + 1).fill(INF)); D[0][0] = 0;
  for(let i = 0; i <= m; i++) for(let j = 0; j <= k; j++){
    if(i > 0) D[i][j] = Math.min(D[i][j], D[i - 1][j] + 1);
    if(j > 0) D[i][j] = Math.min(D[i][j], D[i][j - 1] + 1);
    if(i > 0 && j > 0){
      const a = o[i - 1], b = n[j - 1];
      const c = a === b ? 0 : (a.toUpperCase() === "O" && b === "0" ? 0.5 : 1);
      D[i][j] = Math.min(D[i][j], D[i - 1][j - 1] + c);
    }
  }
  const ops = []; let i = m, j = k;
  while(i > 0 || j > 0){
    const a = o[i - 1], b = n[j - 1];
    if(i > 0 && j > 0 && D[i][j] === D[i - 1][j - 1] + (a === b ? 0 : (a.toUpperCase() === "O" && b === "0" ? 0.5 : 1))){
      if(a !== b) ops.push(a.toUpperCase() === "O" && b === "0" ? { t: "O0" } : { t: "sub", a, b });
      i--; j--;
    } else if(i > 0 && D[i][j] === D[i - 1][j] + 1){ ops.push({ t: "extra", c: a, end: j === k }); i--; }
    else { ops.push({ t: "miss", c: b }); j--; }
  }
  ops.reverse();
  const parts = [];
  const nO = ops.filter(x => x.t === "O0").length;
  if(nO) parts.push(nO > 1 ? "entered letter O instead of 0 (" + nO + " places)" : "entered letter O instead of 0");
  ops.filter(x => x.t === "sub").forEach(x => parts.push(`entered '${x.a}' instead of '${x.b}'`));
  ops.filter(x => x.t === "extra").forEach(x => parts.push(`entered an extra '${x.c}'${x.end ? " at the end" : ""}`));
  ops.filter(x => x.t === "miss").forEach(x => parts.push(`missed '${x.c}'`));
  return parts.length ? "Head teacher " + parts.join("; ") : "Head teacher entered a different number";
}

function perfQtyReason(oldQ, newQ){
  const o = Number(oldQ), n = Number(newQ), d = o - n;
  if(!Number.isFinite(o) || !Number.isFinite(n)) return "Quantity differs from the company invoice";
  return `Quantity: head teacher entered ${o.toLocaleString("en-US")} instead of ${n.toLocaleString("en-US")} (${d > 0 ? "excess" : "short"} by ${Math.abs(d).toLocaleString("en-US")})`;
}

function perfAssembleCorrections(rows, opts){
  const def = SMP_PERFORMAS.invoice_corrections;
  const headers = def.columns.map(c => c.header);
  const model = rows.map(r => ({ ...r, reason: r.kind === "qty" ? perfQtyReason(r.old, r.new) : perfInvoiceReason(r.old, r.new) }));
  const aoa = [headers];
  model.forEach(x => aoa.push([x.emis ? String(x.emis) : "", x.school, "Inventory Received", `${x.tehsil || ""} ${x.wing || ""}`.trim(),
    x.type, x.kind === "qty" ? x.challan : x.new, x.old, x.new, x.reason, "", ""]));
  const cols = [11, 34, 20, 22, 10, 18, 18, 18, 50, 18, 18].map(w => ({ wch: w }));
  return { sheets: [{ name: "Corrections", aoa, merges: [], cols, headerRow: 1 }], model, title: `Correction Request | ${opts.scopeLabel || ""} | up to ${perfDMY(opts.date)}` };
}

const SMP_PERFORMA_BUILDERS = {
  daily_updates: perfAssembleDaily,
  invoice_corrections: perfAssembleCorrections,
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
async function perfSchools(ctx){
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

  return { schools, ids };
}

async function perfCollect(ctx){
  // ctx: { scope: "markaz"|"tehsil"|"district", markazId, tehsil, wing, date }
  const [milk, biscuit] = cache.products;
  if(!milk || !biscuit) throw new Error("Products are not loaded");

  const { schools, ids } = await perfSchools(ctx);

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

async function perfCollectCorrections(ctx){
  // A correction is a head-teacher inventory entry that disagrees with the company invoice:
  // a mistyped challan number, or a different quantity. Rows with no company record are left out
  // (there is nothing to correct them to), and so are rows already settled on school totals.
  const { schools, ids } = await perfSchools(ctx);
  const byId = {}; schools.forEach(x => { byId[x.id] = x; });
  const prodById = {}; cache.products.forEach(p => { prodById[p.id] = p; });
  const wantIds = ctx.product ? cache.products.filter(p => p.product_name.toLowerCase().includes(ctx.product)).map(p => p.id) : null;
  const out = [];
  for(let i = 0; i < ids.length; i += 80){
    const chunk = ids.slice(i, i + 80);
    const { data, error } = await smpFetchAll(() => {
      let q = sb.from("v_three_way_comparison")
        .select("school_id,product_id,delivery_date,invoice_number,company_invoice_number,company_qty,head_challan,head_qty,head_invoice_differs,settled_on_totals")
        .in("school_id", chunk).not("head_challan", "is", null).not("company_qty", "is", null)
        .not("settled_on_totals", "is", true).lte("delivery_date", ctx.date);
      if(wantIds) q = q.in("product_id", wantIds);
      return q.order("school_id").order("product_id").order("delivery_date").order("company_invoice_number");
    });
    if(error) throw new Error(error.message);
    (data || []).forEach(r => {
      const sc = byId[r.school_id]; if(!sc) return;
      const right = r.company_invoice_number || r.invoice_number;
      const old = (r.head_challan || "").trim();
      const base = { tehsil: sc.markaz?.tehsil, wing: sc.wing, markaz: sc.markaz?.name, emis: sc.emis_code, school: sc.school_name,
        type: prodById[r.product_id]?.product_name || "", date: r.delivery_date, challan: right };
      if(right && old && r.head_invoice_differs && old !== right) out.push({ ...base, kind: "invoice", old, new: right });
      const hq = Number(r.head_qty), cq = Number(r.company_qty);
      if(r.head_qty != null && r.head_qty !== "" && Number.isFinite(hq) && Number.isFinite(cq) && hq !== cq) out.push({ ...base, kind: "qty", old: String(hq), new: String(cq) });
    });
  }
  const order = {}; schools.forEach((x, i) => { order[x.emis_code] = i; });
  out.sort((a, b) => (order[a.emis] - order[b.emis]) || a.type.localeCompare(b.type) || String(a.date).localeCompare(String(b.date)) || (a.kind === "invoice" ? -1 : 1));
  return { rows: out };
}

/* ---------- custom performas (made in the admin Performa designer) ---------- */
// A saved design is { name, title_text, total_row, columns:[{header, kind, field|text|expr}] }.
//   kind "field"   - a school-level figure from the system (PERF_FIELDS)
//   kind "formula" - arithmetic over the sheet's own columns by letter, e.g. G+H or O/F
//   kind "fixed"   - the same text on every row
//   kind "blank"   - left empty to fill in
const PERF_FIELDS = [
  { key: "sr",     label: "Serial number",                 num: true },
  { key: "tw",     label: "Tehsil & wing" },
  { key: "tehsil", label: "Tehsil" },
  { key: "wing",   label: "Wing" },
  { key: "markaz", label: "Markaz" },
  { key: "emis",   label: "EMIS code" },
  { key: "school", label: "School name" },
  { key: "enrol",  label: "Enrolment", num: true },
  { key: "mPrev",  label: "Milk received (previously)", num: true },
  { key: "mToday", label: "Milk received on report date", num: true },
  { key: "mRecv",  label: "Milk received (total)", num: true },
  { key: "mCons",  label: "Milk consumed (total)", num: true },
  { key: "mRem",   label: "Milk remaining stock", num: true },
  { key: "mDays",  label: "Milk days remaining", num: true },
  { key: "mAlert", label: "Milk demand alert (Alert-Demand / NO)" },
  { key: "bPrev",  label: "Biscuit received (previously)", num: true },
  { key: "bToday", label: "Biscuit received on report date", num: true },
  { key: "bRecv",  label: "Biscuit received (total)", num: true },
  { key: "bCons",  label: "Biscuit consumed (total)", num: true },
  { key: "bRem",   label: "Biscuit remaining stock", num: true },
  { key: "bDays",  label: "Biscuit days remaining", num: true },
  { key: "bAlert", label: "Biscuit demand alert (Alert-Demand / NO)" },
  { key: "remarks", label: "Automatic remarks (e.g. enrolment not found)" },
];

// Best-guess mapping from an uploaded header, so the admin mostly just confirms.
function perfGuessField(header){
  const h = String(header || "").toLowerCase().replace(/[^a-z0-9 ]+/g, " ");
  const has = (...w) => w.every(x => h.includes(x));
  const milk = h.includes("milk"), bisc = h.includes("biscuit") || h.includes("biskt");
  if(/\b(sr|s no|serial)\b/.test(h) || h.trim() === "sr no" || h.trim() === "srno") return { kind: "field", field: "sr" };
  if(has("tehsil", "wing") || has("tehsil", "&")) return { kind: "field", field: "tw" };
  if(h.includes("emis")) return { kind: "field", field: "emis" };
  if(h.includes("markaz")) return { kind: "field", field: "markaz" };
  if(h.includes("school") && h.includes("enrol")) return { kind: "field", field: "enrol" };
  if(h.includes("enrol")) return { kind: "field", field: "enrol" };
  if(h.includes("school") && (h.includes("name") || h.trim() === "school")) return { kind: "field", field: "school" };
  if(h.trim() === "school") return { kind: "field", field: "school" };
  if(h.includes("tehsil")) return { kind: "field", field: "tehsil" };
  if(h.includes("wing")) return { kind: "field", field: "wing" };
  if((milk || bisc) && h.includes("alert")) return { kind: "field", field: milk ? "mAlert" : "bAlert" };
  if((milk || bisc) && h.includes("demand")) return { kind: "field", field: milk ? "mAlert" : "bAlert" };
  if((milk || bisc) && (h.includes("days"))) return { kind: "field", field: milk ? "mDays" : "bDays" };
  if((milk || bisc) && (h.includes("consum"))) return { kind: "field", field: milk ? "mCons" : "bCons" };
  if((milk || bisc) && (h.includes("remain") || h.includes("stock"))) return { kind: "field", field: milk ? "mRem" : "bRem" };
  if((milk || bisc) && (h.includes("today"))) return { kind: "field", field: milk ? "mToday" : "bToday" };
  if((milk || bisc) && ((h.includes("previous") || h.includes("prev ") || h.endsWith("prev")))) return { kind: "field", field: milk ? "mPrev" : "bPrev" };
  if((milk || bisc) && (h.includes("receiv"))) return { kind: "field", field: milk ? "mRecv" : "bRecv" };
  if(h.includes("remark")) return { kind: "field", field: "remarks" };
  return { kind: "blank" };
}

// Tiny safe arithmetic evaluator (+ - * / parentheses, numbers, column letters). No eval.
function perfEvalExpr(expr, getVar){
  const t = String(expr).replace(/\s+/g, "").toUpperCase();
  if(!/^[A-Z0-9+\-*\/().]+$/.test(t)) throw new Error("Only numbers, column letters, + - * / and brackets are allowed");
  let i = 0;
  const peek = () => t[i];
  function num(){
    if(peek() === "("){ i++; const v = add(); if(peek() !== ")") throw new Error("Missing )"); i++; return v; }
    if(peek() === "-"){ i++; const v = num(); return v == null ? null : -v; }
    let m = /^[0-9]+(\.[0-9]+)?/.exec(t.slice(i));
    if(m){ i += m[0].length; return Number(m[0]); }
    m = /^[A-Z]{1,2}/.exec(t.slice(i));
    if(m){ i += m[0].length; return getVar(m[0]); }
    throw new Error("Unexpected '" + (peek() || "end") + "'");
  }
  function mul(){ let v = num(); while(peek() === "*" || peek() === "/"){ const op = t[i++]; const r = num(); v = (v == null || r == null) ? null : (op === "*" ? v * r : (r === 0 ? null : v / r)); } return v; }
  function add(){ let v = mul(); while(peek() === "+" || peek() === "-"){ const op = t[i++]; const r = mul(); v = (v == null || r == null) ? null : (op === "+" ? v + r : v - r); } return v; }
  const v = add(); if(i < t.length) throw new Error("Unexpected '" + t[i] + "'");
  return v;
}
function perfExprToExcel(expr, row){ return String(expr).toUpperCase().replace(/\s+/g, "").replace(/\b([A-Z]{1,2})\b/g, `$1${row}`); }

function perfFieldValues(x, i){
  return {
    sr: i + 1, tw: `${x.tehsil || ""} ${x.wing || ""}`.trim(), tehsil: x.tehsil, wing: x.wing, markaz: x.markaz,
    emis: x.emis ? (Number(x.emis) || x.emis) : "", school: x.school, enrol: x.e ?? "",
    mPrev: x.m.prev, mToday: x.m.today, mRecv: x.mRecv, mCons: x.m.cons, mRem: x.mRem, mDays: x.mDays ?? "",
    bPrev: x.b.prev, bToday: x.b.today, bRecv: x.bRecv, bCons: x.b.cons, bRem: x.bRem, bDays: x.bDays ?? "",
    remarks: x.remarks,
  };
}

function perfAssembleCustom(rows, opts, tpl){
  // reuse the daily model for the figures (it already does received/remaining/days/remarks)
  const base = perfAssembleDaily(rows, opts).model;
  const cols = tpl.columns || [];
  const alertM = opts.alertMilk ?? 4, alertB = opts.alertBiscuit ?? 4;
  const isNum = c => c.kind === "formula" || (c.kind === "field" && (PERF_FIELDS.find(f => f.key === c.field) || {}).num);
  const hasTitle = !!(tpl.title_text || "").trim();
  const first = (hasTitle ? 3 : 2);                         // Excel row of first data row
  const aoa = [];
  if(hasTitle) aoa.push([String(tpl.title_text).replace("{date}", perfDMY(opts.date)).replace("{area}", opts.scopeLabel || "").replace("{by}", opts.preparedBy || "")]);
  aoa.push(cols.map(c => c.header));
  const sums = cols.map(() => 0);
  base.forEach((x, i) => {
    const f = perfFieldValues(x, i);
    f.mAlert = x.mDays == null ? "Enrolment?" : (x.mDays < alertM ? "Alert-Demand" : "NO");
    f.bAlert = x.bDays == null ? "Enrolment?" : (x.bDays < alertB ? "Alert-Demand" : "NO");
    const xlRow = first + i;
    const vals = cols.map(c => c.kind === "field" ? f[c.field] : c.kind === "fixed" ? (c.text || "") : "");
    const cell = cols.map((c, ci) => {
      if(c.kind === "formula"){
        let v = null;
        try{ v = perfEvalExpr(c.expr, L => { const k = L.length === 1 ? L.charCodeAt(0) - 65 : (L.charCodeAt(0) - 64) * 26 + L.charCodeAt(1) - 65; const q = vals[k]; return typeof q === "number" ? q : (q === "" || q == null ? 0 : (Number(q) || 0)); }); }catch(e){ v = null; }
        vals[ci] = v == null ? "" : v;
        return { t: v == null ? "s" : "n", f: `IFERROR(${perfExprToExcel(c.expr, xlRow)},"")`, v: v == null ? "" : v };
      }
      return vals[ci];
    });
    cell.forEach((v, ci) => { if(isNum(cols[ci]) && typeof vals[ci] === "number") sums[ci] += vals[ci]; });
    aoa.push(cell);
  });
  if(tpl.total_row !== false && base.length){
    const last = first + base.length - 1;
    const tot = cols.map((c, ci) => {
      if(isNum(c) && c.kind === "field" && c.field !== "sr" && c.field !== "mDays" && c.field !== "bDays") return { t: "n", f: `SUM(${perfColLetter(ci)}${first}:${perfColLetter(ci)}${last})`, v: sums[ci] };
      return null;
    });
    const labelAt = cols.findIndex((c, ci) => tot[ci] == null && c.kind === "field" && ["school", "markaz", "tw"].includes(c.field));
    if(labelAt >= 0) tot[labelAt] = "Total";
    aoa.push(tot);
  }
  const widths = cols.map(c => ({ wch: Math.min(40, Math.max(10, String(c.header).length * 0.7)) }));
  return { sheets: [{ name: (tpl.name || "Performa").slice(0, 28).replace(/[\\\/?*\[\]:]/g, " "), aoa, merges: hasTitle && cols.length ? [{ s: { r: 0, c: 0 }, e: { r: 0, c: cols.length - 1 } }] : [], cols: widths, headerRow: hasTitle ? 2 : 1 }], model: base, title: tpl.name };
}

let PERF_CUSTOM = [];
async function perfLoadCustom(){
  try{
    const { data } = await sb.from("performa_templates").select("*").eq("active", true).order("name");
    PERF_CUSTOM = data || [];
  }catch(e){ PERF_CUSTOM = []; }
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

// What the page knows about the performa currently chosen (built-in or custom).
function perfCurrent(id){
  if(id.startsWith("custom:")){
    const t = PERF_CUSTOM.find(x => x.id === id.slice(7));
    return t ? { kind: "custom", tpl: t, title: t.name, columns: (t.columns || []).map(c => ({ header: c.header, kind: c.kind === "field" ? "data" : c.kind === "formula" ? "formula" : c.kind === "fixed" ? "auto" : "manual",
      src: c.kind === "field" ? ((PERF_FIELDS.find(f => f.key === c.field) || {}).label || c.field) : c.kind === "formula" ? "Formula: " + c.expr : c.kind === "fixed" ? "Fixed text: " + (c.text || "") : "Left blank to fill in" })) } : null;
  }
  const d = SMP_PERFORMAS[id];
  return { kind: id, title: d.title, columns: d.columns };
}

async function renderPerformasSection(){
  const content = document.getElementById("repSectionContent");
  if(currentProfile.role === "school_user"){
    content.innerHTML = `<div class="card"><h3>Performas</h3><p class="sub">Performas are prepared at markaz level or above. Please ask your AEO.</p></div>`;
    return;
  }
  await perfLoadCustom();
  const opt = perfScopeOptions();
  const tehsilOpts = opt.tehsils.map(t => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
  const canWide = opt.isAdmin || currentProfile.role === "tr";
  const perfOptions = () => `<option value="daily_updates">${esc(SMP_PERFORMAS.daily_updates.title)}</option>
    <option value="invoice_corrections">${esc(SMP_PERFORMAS.invoice_corrections.title)}</option>
    ${PERF_CUSTOM.map(t => `<option value="custom:${esc(t.id)}">${esc(t.name)}</option>`).join("")}`;

  content.innerHTML = `
    <div class="card">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px;">
        <h3 style="margin:0;">Performas</h3>
        ${opt.isAdmin ? `<button class="btn-secondary" id="perfDesignBtn" type="button">Performa designer</button>` : ""}
      </div>
      <p class="sub">Official reporting sheets prepared from the ledger. Choose the performa, the area and the date, preview it, then download the Excel file. Performas are prepared and downloaded only from here.</p>
      <form id="perfForm" class="form-row">
        <div><label>Performa</label><select name="performa" id="perfId">${perfOptions()}</select></div>
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
        <div class="perf-stock"><label>Milk alert: days left below</label><input type="number" name="alertMilk" value="4" min="0.5" step="0.5" style="width:90px;"/></div>
        <div class="perf-stock"><label>Biscuit alert: days left below</label><input type="number" name="alertBiscuit" value="4" min="0.5" step="0.5" style="width:90px;"/></div>
        <div class="perf-corr" style="display:none;"><label>Product</label>
          <select name="product"><option value="">Milk and biscuit</option><option value="milk">Milk only</option><option value="biscuit">Biscuit only</option></select></div>
        <div style="align-self:end;"><button class="btn-primary" type="submit" id="perfGo">Prepare performa</button></div>
      </form>
      <div id="perfStatus"></div>
    </div>
    <div id="perfDesigner"></div>
    <div class="card" id="perfResult" style="display:none;">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px; margin-bottom:10px;">
        <h3 style="margin:0;" id="perfResultTitle">Preview</h3>
        <button class="btn-export" id="perfDownload" type="button">Download Excel</button>
      </div>
      <div id="perfNotes"></div>
      <div class="table-wrap"><table id="perfTable" style="font-size:11.5px;"><thead></thead><tbody></tbody></table></div>
      <div id="perfSummaryWrap">
        <h4 style="margin:16px 0 6px;">Summary</h4>
        <div class="table-wrap"><table id="perfSummary" style="font-size:12px;"><thead></thead><tbody></tbody></table></div>
      </div>
    </div>
    <div class="card" id="perfMapCard"></div>`;

  const form = document.getElementById("perfForm");
  const scopeSel = document.getElementById("perfScope");
  const idSel = document.getElementById("perfId");

  const renderMapping = () => {
    const cur = perfCurrent(idSel.value);
    document.getElementById("perfMapCard").innerHTML = cur ? `
      <h3>Data mapping - ${esc(cur.title)}</h3>
      <p class="sub">Where each column comes from. This list is what the download is built from.</p>
      <div class="table-wrap"><table style="font-size:12px;">
        <thead><tr><th>Column</th><th>Type</th><th>Source in the system</th></tr></thead>
        <tbody>${cur.columns.map(c => `<tr><td>${esc(c.header)}</td><td>${c.kind === "data" ? "From system" : c.kind === "formula" ? "Formula" : c.kind === "manual" ? "Fill in" : "Automatic"}</td><td style="white-space:normal;">${esc(c.src)}</td></tr>`).join("")}</tbody>
      </table></div>` : "";
  };
  const syncPerforma = () => {
    const cur = perfCurrent(idSel.value) || { kind: "daily_updates" };
    form.querySelectorAll(".perf-stock").forEach(el => { el.style.display = cur.kind === "invoice_corrections" ? "none" : ""; });
    form.querySelectorAll(".perf-corr").forEach(el => { el.style.display = cur.kind === "invoice_corrections" ? "" : "none"; });
    document.getElementById("perfResult").style.display = "none";
    renderMapping();
  };
  idSel.addEventListener("change", syncPerforma);

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
    const sc = scopeSel.value, ts = document.getElementById("perfTehsil");
    document.getElementById("perfMarkazBox").style.display = sc === "markaz" ? "" : "none";
    document.getElementById("perfTehsilBox").style.display = sc === "district" ? "none" : "";
    // Markaz level: tehsil is optional (just narrows the list). Tehsil level: one must be chosen.
    const keep = ts.value;
    ts.innerHTML = (sc === "markaz" && opt.tehsils.length > 1 ? `<option value="">All</option>` : "") + tehsilOpts;
    if([...ts.options].some(o => o.value === keep)) ts.value = keep;
    fillMarkaz();
  };
  scopeSel.addEventListener("change", syncScope);
  document.getElementById("perfTehsil").addEventListener("change", fillMarkaz);
  document.getElementById("perfWing").addEventListener("change", fillMarkaz);
  syncScope(); syncPerforma();
  (async () => {
    try{
      const { data } = await smpFetchAll(() => scopeSchoolsQuery(sb.from("schools").select("id,markaz_id,wing,markaz!inner(tehsil)").eq("active", true)).order("id"));
      (data || []).forEach(r => { if(r.wing) (wingsByMarkaz[r.markaz_id] = wingsByMarkaz[r.markaz_id] || new Set()).add(r.wing); });
      fillMarkaz();
    }catch(e){ /* filter simply shows every markaz */ }
  })();
  if(!opt.markaz.length) document.getElementById("perfStatus").innerHTML = `<p class="err">No markaz is assigned to your account.</p>`;

  if(opt.isAdmin){
    document.getElementById("perfDesignBtn").addEventListener("click", () => {
      renderPerfDesigner(async () => {                         // after a save/delete: refresh the dropdown
        const keep = idSel.value;
        await perfLoadCustom();
        idSel.innerHTML = perfOptions();
        if([...idSel.options].some(o => o.value === keep)) idSel.value = keep;
        syncPerforma();
      });
    });
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    const scope = fd.get("scope"), pid = fd.get("performa"), cur = perfCurrent(pid);
    const st = document.getElementById("perfStatus"), btn = document.getElementById("perfGo");
    const ctx = { scope, markazId: fd.get("markaz"), tehsil: scope === "tehsil" ? fd.get("tehsil") : null, wing: fd.get("wing"), date: fd.get("date"), product: fd.get("product") || "" };
    const alerts = { milk: Number(fd.get("alertMilk")) || 4, biscuit: Number(fd.get("alertBiscuit")) || 4 };
    if(!cur){ st.innerHTML = `<p class="err">This performa is no longer available.</p>`; return; }
    if(scope === "markaz" && !ctx.markazId){ st.innerHTML = `<p class="err">Select a markaz first.</p>`; return; }
    btn.disabled = true; btn.textContent = "Preparing…";
    st.innerHTML = `<p style="color:var(--ink-soft); font-size:12.5px; margin-top:10px;">Reading the ledger…</p>`;
    try{
      const mk = opt.markaz.find(m => m.id === ctx.markazId);
      const scopeLabel = scope === "markaz" ? `Markaz ${mk?.name || ""}${ctx.wing ? " " + ctx.wing : ""}` : scope === "tehsil" ? `Tehsil ${ctx.tehsil}${ctx.wing ? " " + ctx.wing : ""}` : `All tehsils${ctx.wing ? " " + ctx.wing : ""}`;
      const o = { district: (opt.markaz[0]?.district || "Layyah"), scopeLabel, date: ctx.date, alertMilk: alerts.milk, alertBiscuit: alerts.biscuit,
        preparedBy: currentProfile.full_name || currentUser.email, groupBy: scope === "district" ? "tehsilwing" : "markaz" };
      let out, data;
      if(cur.kind === "invoice_corrections"){
        data = await perfCollectCorrections(ctx);
        out = perfAssembleCorrections(data.rows, o);
      } else {
        data = await perfCollect(ctx);
        out = cur.kind === "custom" ? perfAssembleCustom(data.rows, o, cur.tpl) : perfAssembleDaily(data.rows, o);
      }
      renderPerfPreview(cur.kind, out, data, ctx, alerts);
      const slug = scope === "markaz" ? perfSafeName(mk?.name) : scope === "tehsil" ? perfSafeName(ctx.tehsil) : "district";
      document.getElementById("perfDownload").onclick = () => {
        XLSX.writeFile(perfToWorkbook(out.sheets), `${perfSafeName(cur.title).slice(0, 40)}_${slug}_${ctx.date}.xlsx`);
      };
      st.innerHTML = "";
    }catch(err){
      st.innerHTML = `<p class="err">${esc(err.message)}</p>`;
    }finally{
      btn.disabled = false; btn.textContent = "Prepare performa";
    }
  });
}

function perfCellText(c){ return c && typeof c === "object" ? c.v : c; }

function renderPerfPreview(kind, out, data, ctx, alerts){
  document.getElementById("perfResult").style.display = "";
  document.getElementById("perfResultTitle").textContent = out.title;
  const notes = document.getElementById("perfNotes");
  const wrap = document.getElementById("perfSummaryWrap");
  if(kind === "daily_updates") return renderDailyPreview(out, data, ctx, alerts);
  wrap.style.display = "none";
  const sh = out.sheets[0], head = sh.aoa[sh.headerRow - 1], body = sh.aoa.slice(sh.headerRow);
  if(kind === "invoice_corrections"){
    notes.innerHTML = `<p style="color:var(--ink-soft); font-size:12.5px;">${out.model.length ? out.model.length + " correction line(s): " + out.model.filter(x => x.kind !== "qty").length + " challan number, " + out.model.filter(x => x.kind === "qty").length + " quantity (deliveries up to " + esc(perfDMY(ctx.date)) + "). Compared with the company invoice. Entries with no company record, and entries already settled on school totals, are left out. Reasons are worked out automatically; edit them in Excel if needed." : "No head-teacher challan or quantity mistakes found for this selection."}</p>`;
  } else {
    notes.innerHTML = `<p style="color:var(--ink-soft); font-size:12.5px;">${out.model.length} schools. Figures are counted up to and including ${esc(perfDMY(ctx.date))}. ${data.liveOk ? "Enrolment read live just now." : "<b>Live enrolment file could not be read</b> - system records were used."}</p>`;
  }
  document.querySelector("#perfTable thead").innerHTML = `<tr>${head.map(h => `<th style="white-space:normal;">${esc(h)}</th>`).join("")}</tr>`;
  document.querySelector("#perfTable tbody").innerHTML = body.map(r => `<tr>${head.map((_, i) => { const v = perfCellText(r[i]); return `<td style="white-space:normal;">${typeof v === "number" ? (Math.round(v * 100) / 100).toLocaleString() : esc(v)}</td>`; }).join("")}</tr>`).join("");
}

function renderDailyPreview(out, data, ctx, alerts){
  const def = SMP_PERFORMAS.daily_updates;
  const wrap = document.getElementById("perfSummaryWrap"); wrap.style.display = "";
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
      mAlert: x.mDays == null ? "Enrolment?" : (x.mDays < alerts.milk ? "Alert-Demand" : "NO"),
      bAlert: x.bDays == null ? "Enrolment?" : (x.bDays < alerts.biscuit ? "Alert-Demand" : "NO"), remarks: x.remarks };
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

/* ---------- Performa designer (admins only; the database enforces this too) ---------- */
function renderPerfDesigner(onChanged){
  if(!["admin", "super_admin"].includes(currentProfile.role)) return;
  const box = document.getElementById("perfDesigner");
  let cols = [], editingId = null;
  const kinds = [["field", "System data"], ["formula", "Formula"], ["fixed", "Fixed text"], ["blank", "Leave blank"]];

  const draw = () => {
    box.innerHTML = `
    <div class="card">
      <div style="display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:10px;">
        <h3 style="margin:0;">Performa designer <span class="pill">Admin</span></h3>
        <button class="btn-secondary" id="pdClose" type="button">Close</button>
      </div>
      <p class="sub">Upload a blank Excel performa. Its column headings become the columns; pick where each one gets its data. Works for school-wise tables (one row per school). Formulas use the sheet's own column letters, for example <b>G+H</b> or <b>O/F</b>.</p>
      <div class="form-row">
        <div><label>Blank performa (.xlsx, .xls, .csv)</label><input type="file" id="pdFile" accept=".xlsx,.xls,.csv"/></div>
        <div><label>Performa name</label><input type="text" id="pdName" placeholder="e.g. Weekly stock report"/></div>
        <div><label>Title line (optional)</label><input type="text" id="pdTitle" placeholder="e.g. CM Meal Program, District Layyah - {area} - {date}"/></div>
        <div><label style="display:flex;gap:6px;align-items:center;margin-top:22px;"><input type="checkbox" id="pdTotal" checked style="width:auto;"/> Add a total row</label></div>
      </div>
      <div id="pdMsg"></div>
      <div class="table-wrap" id="pdTableWrap" style="${cols.length ? "" : "display:none;"}">
        <table style="font-size:12px;"><thead><tr><th>Col</th><th>Heading</th><th>Data source</th><th>Detail</th></tr></thead>
        <tbody>${cols.map((c, i) => `<tr data-i="${i}">
          <td>${perfColLetter(i)}</td>
          <td><input type="text" class="pd-h" value="${esc(c.header)}"/></td>
          <td><select class="pd-k">${kinds.map(([v, l]) => `<option value="${v}"${c.kind === v ? " selected" : ""}>${l}</option>`).join("")}</select></td>
          <td>${c.kind === "field" ? `<select class="pd-f">${PERF_FIELDS.map(f => `<option value="${f.key}"${c.field === f.key ? " selected" : ""}>${esc(f.label)}</option>`).join("")}</select>`
            : c.kind === "formula" ? `<input type="text" class="pd-e" value="${esc(c.expr || "")}" placeholder="e.g. G+H"/>`
            : c.kind === "fixed" ? `<input type="text" class="pd-t" value="${esc(c.text || "")}"/>` : `<span style="color:var(--ink-soft)">Empty cells</span>`}</td>
        </tr>`).join("")}</tbody></table>
      </div>
      <div class="actions-row" style="margin-top:10px; ${cols.length ? "" : "display:none;"}">
        <button class="btn-primary" id="pdSave" type="button">${editingId ? "Save changes" : "Save performa"}</button>
      </div>
      <h4 style="margin:16px 0 6px;">Saved performas</h4>
      <div id="pdSaved">${PERF_CUSTOM.length ? PERF_CUSTOM.map(t => `<div style="display:flex;gap:8px;align-items:center;margin:4px 0;"><span style="flex:1;">${esc(t.name)} <span style="color:var(--ink-soft);font-size:12px;">(${(t.columns || []).length} columns)</span></span>
        <button class="btn-secondary pd-edit" data-id="${esc(t.id)}" type="button">Edit</button><button class="btn-secondary pd-del" data-id="${esc(t.id)}" type="button">Delete</button></div>`).join("") : `<p class="sub">None yet.</p>`}</div>
    </div>`;
    wire();
  };

  const readInputs = () => {
    box.querySelectorAll("#pdTableWrap tbody tr").forEach(tr => {
      const i = Number(tr.dataset.i), c = cols[i];
      c.header = tr.querySelector(".pd-h").value;
      c.kind = tr.querySelector(".pd-k").value;
      c.field = tr.querySelector(".pd-f")?.value ?? c.field;
      c.expr = tr.querySelector(".pd-e")?.value ?? c.expr;
      c.text = tr.querySelector(".pd-t")?.value ?? c.text;
    });
  };
  const keepTop = () => ({ name: box.querySelector("#pdName").value, title: box.querySelector("#pdTitle").value, total: box.querySelector("#pdTotal").checked });
  let top = { name: "", title: "", total: true };
  const restoreTop = () => { box.querySelector("#pdName").value = top.name; box.querySelector("#pdTitle").value = top.title; box.querySelector("#pdTotal").checked = top.total; };
  const msg = (h, bad) => { box.querySelector("#pdMsg").innerHTML = `<p class="${bad ? "err" : ""}" style="${bad ? "" : "color:var(--ink-soft);font-size:12.5px;"}">${h}</p>`; };

  function wire(){
    restoreTop();
    box.querySelector("#pdClose").onclick = () => { box.innerHTML = ""; };
    box.querySelector("#pdFile").onchange = async (e) => {
      const f = e.target.files[0]; if(!f) return;
      try{
        const wb = XLSX.read(await f.arrayBuffer(), { type: "array" });
        const ws = wb.Sheets[wb.SheetNames[0]];
        const grid = XLSX.utils.sheet_to_json(ws, { header: 1, defval: "" });
        // headings = first row (within the first 10) that has at least 3 filled cells
        let hr = grid.slice(0, 10).findIndex(r => r.filter(v => String(v).trim() !== "").length >= 3);
        if(hr < 0) throw new Error("Could not find a heading row (at least 3 filled cells) in the first 10 rows");
        const heads = grid[hr].map(v => String(v).replace(/\s+/g, " ").trim()).filter(v => v !== "");
        top = keepTop(); if(!top.name) top.name = f.name.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ");
        cols = heads.map(h => ({ header: h, ...perfGuessField(h) }));
        editingId = null; draw();
        msg(`${cols.length} columns read from "${esc(f.name)}" (row ${hr + 1}). Check each guess below, then save. Formulas in the uploaded file are not copied - add them here as "Formula" columns.`);
      }catch(err){ msg(esc(err.message), true); }
    };
    box.querySelectorAll("#pdTableWrap .pd-k").forEach(sel => sel.addEventListener("change", () => {
      readInputs(); top = keepTop();
      const c = cols[Number(sel.closest("tr").dataset.i)];
      if(c.kind === "field" && !c.field) c.field = "school";
      draw();
    }));
    box.querySelector("#pdSave") && (box.querySelector("#pdSave").onclick = async () => {
      readInputs(); top = keepTop();
      if(!top.name.trim()) return msg("Give the performa a name.", true);
      if(cols.some(c => !String(c.header).trim())) return msg("Every column needs a heading.", true);
      for(const c of cols){
        if(c.kind === "formula"){
          try{ perfEvalExpr(c.expr || "", () => 1); }catch(e){ return msg(`Formula for "${esc(c.header)}": ${esc(e.message)}`, true); }
          const bad = (String(c.expr).toUpperCase().match(/\b[A-Z]{1,2}\b/g) || []).find(L => (L.length === 1 ? L.charCodeAt(0) - 65 : (L.charCodeAt(0) - 64) * 26 + L.charCodeAt(1) - 65) >= cols.length);
          if(bad) return msg(`Formula for "${esc(c.header)}" uses column ${bad}, which does not exist.`, true);
        }
      }
      const rec = { name: top.name.trim(), title_text: top.title.trim() || null, total_row: top.total, active: true, updated_at: new Date().toISOString(),
        columns: cols.map(c => ({ header: String(c.header).trim(), kind: c.kind, ...(c.kind === "field" ? { field: c.field } : {}), ...(c.kind === "formula" ? { expr: c.expr } : {}), ...(c.kind === "fixed" ? { text: c.text || "" } : {}) })) };
      const q = editingId ? sb.from("performa_templates").update(rec).eq("id", editingId) : sb.from("performa_templates").insert(rec);
      const { error } = await q;
      if(error) return msg(esc(error.message.includes("duplicate") ? "A performa with this name already exists." : error.message), true);
      toast("Performa saved");
      cols = []; editingId = null; top = { name: "", title: "", total: true };
      await onChanged(); await perfLoadCustom(); draw();
    });
    box.querySelectorAll(".pd-edit").forEach(b => b.onclick = () => {
      const t = PERF_CUSTOM.find(x => x.id === b.dataset.id); if(!t) return;
      cols = (t.columns || []).map(c => ({ ...c })); editingId = t.id;
      top = { name: t.name, title: t.title_text || "", total: t.total_row !== false }; draw();
      msg(`Editing "${esc(t.name)}".`);
    });
    box.querySelectorAll(".pd-del").forEach(b => b.onclick = async () => {
      const t = PERF_CUSTOM.find(x => x.id === b.dataset.id); if(!t || !confirm(`Delete "${t.name}"? Users will no longer see it.`)) return;
      const { error } = await sb.from("performa_templates").update({ active: false, updated_at: new Date().toISOString() }).eq("id", t.id);
      if(error) return toast(error.message, "bad");
      toast("Performa deleted"); await onChanged(); await perfLoadCustom(); draw();
    });
  }
  draw();
}

if(typeof module !== "undefined") module.exports = { perfAssembleDaily, perfAssembleCorrections, perfInvoiceReason, perfQtyReason, perfAssembleCustom, perfEvalExpr, perfGuessField, perfColLetter, SMP_PERFORMAS };
