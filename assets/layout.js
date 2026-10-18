// Shared official-portal navigation shell: a persistent sidebar (fixed on desktop/tablet,
// a slide-in drawer on phones) rendered the same way on every page, driven by the
// logged-in profile's role. Every page calls renderSidebarNav() once currentProfile is
// known (right where it already sets the header's whoBox), so this file has no boot logic
// of its own - it only builds and inserts DOM, and never touches auth, data, or any
// existing page script.
//
// Top-level items stay one click away; everything else (missing-consumption checks,
// period reports & demand, the company/AEO comparison, and the schedule admin panel)
// is grouped under one "Operations" menu, since those are all reporting/administration
// tools rather than day-to-day data entry.
const SMP_NAV = [
  { href: "dashboard.html",   label: "Dashboard" },
  { href: "inventory.html",   label: "Inventory Received" },
  { href: "consumption.html", label: "Consumption" },
  { href: "transfers.html",   label: "Transfer & Rationalization" },
  {
    label: "Operations",
    group: true,
    children: [
      { href: "operations.html",        label: "Missing Consumption & Adjustments" },
      { href: "report-generation.html", label: "Reports & Demand" },
      { href: "report-comparison.html", label: "Company vs AEO Comparison", roles: ["admin", "super_admin", "tr"] },
      { href: "admin.html",             label: "Admin Panel", roles: ["admin", "super_admin"] },
    ],
  },
];

function smpCurrentPage(){
  return (location.pathname.split("/").pop() || "dashboard.html").split("?")[0];
}
function smpAllowed(item){
  return !item.roles || (currentProfile && item.roles.includes(currentProfile.role));
}
function smpJurisdictionLabel(){
  // A short second line under the user's name/role in the header: home markaz (+ N more
  // for an AEO holding several), or the tehsil/wing for a TR. Falls back quietly if the
  // markaz reference data hasn't loaded on this page.
  if(!currentProfile) return "";
  const byId = Object.fromEntries((typeof cache !== "undefined" && cache.markaz ? cache.markaz : []).map(m => [m.id, m]));
  if(currentProfile.role === "aeo"){
    const home = byId[currentProfile.markaz_id];
    const extra = (currentProfile.extra_markaz_ids || []).length;
    if(!home) return "";
    return home.name + (extra ? ` +${extra} more` : "");
  }
  if(currentProfile.role === "tr"){
    return [currentProfile.tehsil, currentProfile.wing_scope].filter(Boolean).join(" · ");
  }
  return "";
}

function renderSidebarNav(){
  if(!currentProfile) return;
  const page = smpCurrentPage();
  const isChildActive = (item) => item.children && item.children.some(c => c.href === page);

  function renderLink(item){
    const active = item.href === page;
    return `<a class="sn-link${active ? " active" : ""}" href="${item.href}">${esc(item.label)}</a>`;
  }
  function renderGroup(item, idx){
    const visibleChildren = item.children.filter(smpAllowed);
    if(!visibleChildren.length) return "";
    const open = isChildActive(item);
    return `
      <button type="button" class="sn-group" data-group="${idx}" aria-expanded="${open}">
        <span class="sn-group-label">${esc(item.label)}</span><span class="sn-caret">&#9656;</span>
      </button>
      <div class="sn-subnav${open ? "" : " hidden"}" data-group-panel="${idx}">
        ${visibleChildren.map(renderLink).join("")}
      </div>`;
  }

  const navHtml = SMP_NAV.filter(smpAllowed).map((item, idx) =>
    item.group ? renderGroup(item, idx) : renderLink(item)
  ).join("");

  let nav = document.getElementById("sidebarNav");
  let overlay = document.getElementById("sidebarOverlay");
  if(!nav){
    nav = document.createElement("div");
    nav.id = "sidebarNav";
    document.body.insertBefore(nav, document.body.firstChild);
    overlay = document.createElement("div");
    overlay.id = "sidebarOverlay";
    document.body.appendChild(overlay);
    document.body.classList.add("has-sidebar");

    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.id = "sidebarToggle";
    toggle.setAttribute("aria-label", "Open menu");
    toggle.innerHTML = "&#9776;";
    const brand = document.querySelector("#topbar .brand");
    if(brand) brand.insertBefore(toggle, brand.firstChild);

    function closeDrawer(){ document.body.classList.remove("sidebar-open"); }
    toggle.addEventListener("click", () => document.body.classList.toggle("sidebar-open"));
    overlay.addEventListener("click", closeDrawer);
    nav.addEventListener("click", (e) => { if(e.target.closest("a.sn-link")) closeDrawer(); });
  }

  nav.innerHTML = `
    <div class="sn-brand">
      <div class="sn-title">School Meal Program</div>
      <div class="sn-sub">Punjab School Education Department</div>
    </div>
    <nav>${navHtml}</nav>`;

  nav.querySelectorAll("button.sn-group").forEach(btn => {
    btn.addEventListener("click", () => {
      const panel = nav.querySelector(`[data-group-panel="${btn.dataset.group}"]`);
      const open = btn.getAttribute("aria-expanded") === "true";
      btn.setAttribute("aria-expanded", String(!open));
      panel.classList.toggle("hidden", open);
    });
  });

  // Enrich the header's who-box with a jurisdiction line, once markaz reference data is
  // available - purely additive to whatever the page already put there (name + role).
  const jurisdiction = smpJurisdictionLabel();
  if(jurisdiction){
    const who = document.getElementById("whoBox");
    if(who && !who.querySelector(".who-jurisdiction")){
      who.insertAdjacentHTML("beforeend", `<br><span class="who-jurisdiction" style="opacity:.85;">${esc(jurisdiction)}</span>`);
    }
  }
}


/* ===== Live "search by word" for tables =====
   smpLiveSearch(input, scope, tableSelector, countEl): as the user types, hide every row of the matching tables
   (inside `scope`) that does not contain ALL the words typed - school name, EMIS, markaz, invoice #, product,
   remarks, anything shown in the row. Invoice-style words also match with O/0 and punctuation ignored.
   Rows re-rendered later (after a filter/reload) are filtered again automatically. */
function smpLiveSearch(input, scope, tableSelector, countEl){
  if(!input || !scope) return;
  if(scope.__smpLive) scope.__smpLive.disconnect();
  const norm = v => String(v ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "").replace(/O/g, "0");
  let queued = false;
  function apply(){
    queued = false;
    const words = input.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0, total = 0;
    scope.querySelectorAll(tableSelector).forEach((table, tIdx) => {
      table.querySelectorAll("tbody tr").forEach(tr => {
        // single-cell rows are messages ("Loading...", "No data") - never hide them
        if(tr.children.length === 1 && tr.firstElementChild.hasAttribute("colspan")){ tr.style.display = ""; return; }
        const text = tr.textContent.toLowerCase();
        const tn = norm(text);
        const ok = words.every(w => text.includes(w) || (norm(w).length >= 4 && tn.includes(norm(w))));
        tr.style.display = ok ? "" : "none";
        // The "Showing X of Y" count refers to the first (main) table when a page has several.
        if(tIdx === 0){ total++; if(ok) shown++; }
      });
    });
    if(countEl){
      const msg = words.length ? `Showing ${shown} of ${total}` : "";
      if(countEl.textContent !== msg) countEl.textContent = msg;
    }
  }
  const schedule = () => { if(!queued){ queued = true; requestAnimationFrame(apply); } };
  input.addEventListener("input", apply);
  const obs = new MutationObserver(schedule);
  obs.observe(scope, { childList: true, subtree: true });
  scope.__smpLive = obs;
  apply();
}
