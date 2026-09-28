// "Sync" button shown to the left of the logged-in user's name on every page.
// Re-pulls the user's OWN role / markaz / extra markaz / tehsil / wing from A-I-DB (edge function
// "sync-me"), clears cached reference data, then reloads so the new scope applies immediately.
(function(){
  var COOLDOWN_MS = 8000;
  function inject(){
    var who = document.getElementById("whoBox");
    if(!who || document.getElementById("syncMeBtn")) return;
    var btn = document.createElement("button");
    btn.type = "button";
    btn.id = "syncMeBtn";
    btn.className = "btn-secondary sync-me-btn";
    btn.title = "Refresh my markaz / scope from A-I-DB";
    btn.innerHTML = "&#8635; Sync";
    who.parentNode.insertBefore(btn, who);
    btn.addEventListener("click", run);
  }
  function say(msg, bad){
    if(typeof toast === "function"){ toast(msg, bad ? "bad" : undefined); } else { alert(msg); }
  }
  async function run(){
    var btn = document.getElementById("syncMeBtn");
    if(!btn || btn.disabled) return;
    btn.disabled = true; btn.innerHTML = "Syncing…";
    var reload = false;
    try{
      if(typeof sb === "undefined") throw new Error("Not signed in yet - please wait a moment.");
      var s = await sb.auth.getSession();
      var token = s && s.data && s.data.session && s.data.session.access_token;
      if(!token) throw new Error("Session expired - please sign in again.");
      var res = await fetch(SMP_CONFIG.SUPABASE_URL + "/functions/v1/sync-me", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + token, apikey: SMP_CONFIG.SUPABASE_ANON_KEY },
        body: "{}"
      });
      var data = {};
      try{ data = await res.json(); }catch(e){}
      if(!res.ok) throw new Error(data.error || ("Sync failed (" + res.status + ")"));
      try{ Object.keys(sessionStorage).filter(function(k){ return k.indexOf("smp_ref_") === 0; }).forEach(function(k){ sessionStorage.removeItem(k); }); }catch(e){}
      var msg = "Synced from A-I-DB" + (data.extra_markaz_count ? " - " + data.extra_markaz_count + " extra markaz assigned." : ".");
      if(data.warnings && data.warnings.length) msg += " " + data.warnings.join(" ");
      say(msg, data.warnings && data.warnings.length);
      reload = true;
      setTimeout(function(){ location.reload(); }, data.warnings && data.warnings.length ? 3500 : 1200);
    }catch(err){
      console.error("[SMP] self sync failed:", err && err.message);
      say((err && err.message) || "Sync failed", true);
    }finally{
      if(!reload) setTimeout(function(){ btn.disabled = false; btn.innerHTML = "&#8635; Sync"; }, COOLDOWN_MS);
    }
  }
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", inject); else inject();
})();
