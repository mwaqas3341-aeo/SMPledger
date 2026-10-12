// "Report email" button shown next to Sync in the top bar. Lets AEOs / TRs / admins set the real
// inbox where their markaz consumption reports are delivered (login emails are @smp.local
// placeholders). Writes only profiles.report_email on the user's OWN row; the database guard
// (trg_profiles_guard) rejects any other self-service change, so this cannot be used to alter
// role or markaz. Purely additive: it reads the page's existing `sb` and `currentProfile`.
(function(){
  var EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
  function say(msg, bad){
    if(typeof toast === "function"){ toast(msg, bad ? "bad" : undefined); } else { alert(msg); }
  }
  function label(){
    var has = !!(currentProfile && currentProfile.report_email);
    return has ? "&#9993; Report email" : "&#9993; Set report email";
  }
  function paint(btn){
    btn.innerHTML = label();
    btn.title = currentProfile.report_email
      ? "Reports go to " + currentProfile.report_email + " - click to change"
      : "No report email set yet - click to add the inbox where your markaz reports should be sent";
    btn.style.borderColor = currentProfile.report_email ? "" : "var(--warn-fg)";
  }
  async function run(btn){
    var current = currentProfile.report_email || "";
    var input = prompt("Email address for your automatic markaz reports (leave empty to stop receiving them):", current);
    if(input === null) return;
    var v = input.trim().toLowerCase();
    if(v && !EMAIL_RE.test(v)){ say("That doesn't look like a valid email address.", true); return; }
    if(v === current) return;
    btn.disabled = true;
    try{
      var res = await sb.from("profiles").update({ report_email: v || null }).eq("id", currentProfile.id).select("report_email").single();
      if(res.error) throw new Error(res.error.message);
      if((res.data && res.data.report_email || "") !== v) throw new Error("The change was not saved - please try again.");
      currentProfile.report_email = v || null;
      paint(btn);
      say(v ? "Report email saved: " + v : "Report email removed.");
    }catch(err){
      console.error("[SMP] report email save failed:", err && err.message);
      say((err && err.message) || "Could not save the email.", true);
    }finally{
      btn.disabled = false;
    }
  }
  function mount(){
    try{
      if(!currentProfile || ["aeo","tr","admin"].indexOf(currentProfile.role) < 0) return;
      // Only once the database has the column (migration applied); otherwise stay hidden.
      if(!("report_email" in currentProfile)) return;
      var who = document.getElementById("whoBox");
      if(!who || document.getElementById("reportEmailBtn")) return;
      var btn = document.createElement("button");
      btn.type = "button";
      btn.id = "reportEmailBtn";
      btn.className = "btn-secondary sync-me-btn";
      who.parentNode.insertBefore(btn, who);
      paint(btn);
      btn.addEventListener("click", function(){ run(btn); });
    }catch(e){ console.error("[SMP] report email button:", e && e.message); }
  }
  function boot(){
    var tries = 0;
    var t = setInterval(function(){
      tries++;
      var ready = false;
      try{ ready = (typeof sb !== "undefined") && (typeof currentProfile !== "undefined") && !!currentProfile; }catch(e){}
      if(ready){ clearInterval(t); mount(); }
      else if(tries > 80){ clearInterval(t); }
    }, 250);
  }
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
})();
