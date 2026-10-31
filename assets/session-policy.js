// Two session-wide behaviours, loaded on every signed-in page:
//  1) AUTO LOGOUT: every user is signed out 8 hours after logging in (checked every 30 s, on tab focus and on page load;
//     a gentle warning appears for the last 10 minutes).
//  2) LOGIN POPUP: once per login, signed-in users (not the Admin) see an offer for the WhatsApp auto data collection service.
// Self-contained (own styles), never throws into the page.
(function(){
  var SESSION_HOURS = 8;
  var LOGIN_KEY = "smp_login_at";          // set by index.html at sign-in (localStorage, shared by all tabs)
  var PROMO_KEY = "smp_promo_pending";     // set by index.html at sign-in (sessionStorage); consumed by the first page that shows it
  var PROMO_ENABLED = true;
  var PRICE_TEXT = "Rs. 200";
  var PERIOD_TEXT = "per month";
  var CONTACT_TEXT = "Contact the program Admin to subscribe.";   // put a phone / WhatsApp number here when ready, e.g. "WhatsApp 03XX-XXXXXXX to subscribe."
  var LIMIT_MS = SESSION_HOURS * 3600 * 1000, WARN_MS = 10 * 60 * 1000;
  var ended = false;

  function loginAt(){
    var v = 0;
    try{ v = parseInt(localStorage.getItem(LOGIN_KEY) || "0", 10) || 0; }catch(e){}
    if(!v){ v = Date.now(); try{ localStorage.setItem(LOGIN_KEY, String(v)); }catch(e){} }   // sessions started before this feature: count from now
    return v;
  }
  function css(){
    if(document.getElementById("smpSpCss")) return;
    var s = document.createElement("style"); s.id = "smpSpCss";
    s.textContent =
      ".smp-sp-bar{position:fixed;left:50%;transform:translateX(-50%);bottom:14px;z-index:99998;background:#7a3e00;color:#fff;padding:10px 16px;border-radius:999px;font:14px/1.3 system-ui,sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.3);max-width:92vw;text-align:center}" +
      ".smp-pr-ov{position:fixed;inset:0;background:rgba(10,20,40,.62);display:flex;align-items:center;justify-content:center;z-index:99990;padding:14px;animation:smpPrFade .25s ease}" +
      "@keyframes smpPrFade{from{opacity:0}to{opacity:1}}@keyframes smpPrUp{from{transform:translateY(18px);opacity:0}to{transform:none;opacity:1}}" +
      ".smp-pr-box{position:relative;background:#fff;color:#1b1f23;border-radius:18px;max-width:440px;width:100%;overflow:hidden;box-shadow:0 24px 70px rgba(0,0,0,.4);font-family:system-ui,-apple-system,'Segoe UI',sans-serif;animation:smpPrUp .3s ease}" +
      ".smp-pr-head{background:linear-gradient(135deg,#0b5cad 0%,#1e8e5a 100%);color:#fff;padding:26px 22px 20px;text-align:center}" +
      ".smp-pr-ico{font-size:40px;line-height:1;margin-bottom:6px}" +
      ".smp-pr-head h3{margin:0;font-size:21px;line-height:1.25;font-weight:700}" +
      ".smp-pr-head p{margin:6px 0 0;font-size:14px;opacity:.92}" +
      ".smp-pr-x{position:absolute;top:10px;right:10px;width:34px;height:34px;border-radius:50%;border:0;background:rgba(255,255,255,.22);color:#fff;font-size:22px;line-height:34px;cursor:pointer;padding:0}" +
      ".smp-pr-x:hover{background:rgba(255,255,255,.36)}" +
      ".smp-pr-body{padding:18px 22px 20px}" +
      ".smp-pr-list{list-style:none;margin:0 0 16px;padding:0}" +
      ".smp-pr-list li{display:flex;gap:10px;align-items:flex-start;font-size:14.5px;margin:0 0 10px;line-height:1.4}" +
      ".smp-pr-list li b.t{flex:0 0 22px;height:22px;border-radius:50%;background:#e6f6ee;color:#1e8e5a;text-align:center;line-height:22px;font-size:13px}" +
      ".smp-pr-price{display:flex;align-items:baseline;justify-content:center;gap:6px;background:#f3f8ff;border:1px dashed #9cc2ee;border-radius:12px;padding:12px;margin-bottom:12px}" +
      ".smp-pr-price .a{font-size:30px;font-weight:800;color:#0b5cad}.smp-pr-price .p{font-size:14px;color:#555}" +
      ".smp-pr-contact{text-align:center;font-size:13.5px;color:#444;margin:0 0 14px}" +
      ".smp-pr-btn{display:block;width:100%;padding:12px;border-radius:10px;border:0;background:#0b5cad;color:#fff;font-size:15px;font-weight:600;cursor:pointer}" +
      ".smp-pr-btn.ghost{background:#eef1f5;color:#334;margin-top:8px}";
    document.head.appendChild(s);
  }

  // ---------- 8-hour auto logout ----------
  function bar(msg){
    css();
    var b = document.getElementById("smpSpBar");
    if(!b){ b = document.createElement("div"); b.id = "smpSpBar"; b.className = "smp-sp-bar"; document.body.appendChild(b); }
    b.textContent = msg;
  }
  async function endSession(){
    if(ended) return; ended = true;
    try{
      if(typeof sb !== "undefined" && sb.auth){
        await Promise.race([sb.auth.signOut(), new Promise(function(r){ setTimeout(r, 3500); })]);
      }
    }catch(e){}
    try{ localStorage.removeItem(LOGIN_KEY); sessionStorage.removeItem(PROMO_KEY); }catch(e){}
    location.replace("index.html?expired=1");
  }
  function check(){
    if(ended) return;
    var left = loginAt() + LIMIT_MS - Date.now();
    if(left <= 0){ endSession(); return; }
    if(left <= WARN_MS && document.body){ bar("You will be signed out automatically in " + Math.max(1, Math.ceil(left / 60000)) + " min (8-hour limit). Please save your work."); }
  }
  check();
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", check);
  setInterval(check, 30000);
  document.addEventListener("visibilitychange", function(){ if(!document.hidden) check(); });
  window.addEventListener("focus", check);
  window.addEventListener("storage", function(e){ if(e.key === LOGIN_KEY && !e.newValue){ endSession(); } });   // signed out in another tab

  // ---------- login popup ----------
  function showPromo(){
    css();
    try{ sessionStorage.removeItem(PROMO_KEY); }catch(e){}
    var o = document.createElement("div"); o.className = "smp-pr-ov"; o.id = "smpPrOv";
    o.innerHTML =
      '<div class="smp-pr-box" role="dialog" aria-modal="true" aria-labelledby="smpPrT">' +
        '<div class="smp-pr-head"><button type="button" class="smp-pr-x" id="smpPrX" aria-label="Close">&times;</button>' +
          '<div class="smp-pr-ico">&#128241;&#10024;</div>' +
          '<h3 id="smpPrT">Automate your daily consumption reporting</h3>' +
          '<p>Let WhatsApp collect the data for you</p></div>' +
        '<div class="smp-pr-body">' +
          '<ul class="smp-pr-list">' +
            '<li><b class="t">&#10003;</b><span><b>Auto data collector</b> - school heads share the day\'s figures in your WhatsApp group and the system reads them automatically.</span></li>' +
            '<li><b class="t">&#10003;</b><span><b>Straight into the reporting system</b> - the collected consumption is added after your one-tap approval (or automatically at a time you choose).</span></li>' +
            '<li><b class="t">&#10003;</b><span><b>Less typing, fewer mistakes</b> - missing schools are listed for you every day.</span></li>' +
          '</ul>' +
          '<div class="smp-pr-price"><span class="a">' + PRICE_TEXT + '</span><span class="p">' + PERIOD_TEXT + '</span></div>' +
          '<p class="smp-pr-contact">' + CONTACT_TEXT + '</p>' +
          '<button type="button" class="smp-pr-btn ghost" id="smpPrLater">Maybe later</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(o);
    function close(){ if(o.parentNode) o.remove(); document.removeEventListener("keydown", onKey); }
    function onKey(e){ if(e.key === "Escape") close(); }
    document.getElementById("smpPrX").addEventListener("click", close);
    document.getElementById("smpPrLater").addEventListener("click", close);
    o.addEventListener("click", function(e){ if(e.target === o) close(); });
    document.addEventListener("keydown", onKey);
    document.getElementById("smpPrX").focus();
  }
  function maybePromo(){
    var pending = false;
    try{ pending = sessionStorage.getItem(PROMO_KEY) === "1"; }catch(e){}
    if(!PROMO_ENABLED || !pending) return;
    var tries = 0, t = setInterval(function(){
      tries++;
      var prof = (typeof currentProfile !== "undefined") ? currentProfile : null;
      if(prof && prof.id){
        if(document.getElementById("smpEmOverlay")) return;            // the required Gmail dialog goes first
        clearInterval(t);
        if(prof.role !== "admin") showPromo(); else { try{ sessionStorage.removeItem(PROMO_KEY); }catch(e){} }
      } else if(tries > 60){ clearInterval(t); }
    }, 500);
  }
  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", maybePromo); else maybePromo();
})();
