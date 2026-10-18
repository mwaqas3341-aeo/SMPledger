// Asks each signed-in user for the Gmail address that consumption-report emails will be sent to.
// - Anyone without a saved address is asked on every page until they save one (no skip option).
// - A small "Email" button next to Sync lets anyone view/correct their address at any time.
// It only talks to two database functions (fn_my_notify_email / fn_set_my_notify_email), is self-contained
// (own styles, no dependency on the page's CSS) and never throws into the page.
(function(){
  var ASKED_KEY = "smp_email_asked";
  var GMAIL_RE = /^[a-z0-9._%+-]+@gmail\.com$/;

  function css(){
    if(document.getElementById("smpEmCss")) return;
    var s = document.createElement("style");
    s.id = "smpEmCss";
    s.textContent =
      ".smp-em-overlay{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:100000;padding:16px;}" +
      ".smp-em-box{background:#fff;color:#1b1f23;border-radius:10px;max-width:420px;width:100%;padding:20px;box-shadow:0 10px 40px rgba(0,0,0,.3);font-family:inherit;}" +
      ".smp-em-box h3{margin:0 0 6px;font-size:18px;}" +
      ".smp-em-box p{margin:0 0 12px;font-size:14px;color:#555;}" +
      ".smp-em-box label{display:block;font-size:13px;font-weight:600;margin:10px 0 4px;}" +
      ".smp-em-box input{width:100%;box-sizing:border-box;padding:9px 10px;border:1px solid #bbb;border-radius:6px;font-size:15px;}" +
      ".smp-em-err{color:#b00020;font-size:13px;margin-top:10px;min-height:18px;}" +
      ".smp-em-actions{display:flex;gap:8px;justify-content:flex-end;margin-top:14px;flex-wrap:wrap;}" +
      ".smp-em-actions button{padding:9px 14px;border-radius:6px;border:1px solid #888;background:#f3f3f3;cursor:pointer;font-size:14px;}" +
      ".smp-em-actions button.smp-em-primary{background:#0b5cad;color:#fff;border-color:#0b5cad;}" +
      ".smp-em-actions button:disabled{opacity:.6;cursor:default;}";
    document.head.appendChild(s);
  }
  function say(msg, bad){
    try{ if(typeof toast === "function"){ toast(msg, bad ? "bad" : undefined); return; } }catch(e){}
    alert(msg);
  }
  function ready(){
    return typeof sb !== "undefined" && typeof currentProfile !== "undefined" && currentProfile && currentProfile.id;
  }

  function openModal(current, required){
    if(document.getElementById("smpEmOverlay")) return;
    css();
    var o = document.createElement("div");
    o.id = "smpEmOverlay"; o.className = "smp-em-overlay";
    o.innerHTML =
      '<div class="smp-em-box" role="dialog" aria-modal="true">' +
        '<h3>Your Gmail address</h3>' +
        '<p>Consumption reports for your markaz will be emailed here. Enter the Gmail address you check regularly.' + (required ? ' <b>This is required to continue.</b>' : '') + '</p>' +
        '<label for="smpEmA">Gmail address</label>' +
        '<input id="smpEmA" type="email" inputmode="email" autocomplete="email" placeholder="name@gmail.com" />' +
        '<label for="smpEmB">Confirm Gmail address</label>' +
        '<input id="smpEmB" type="email" inputmode="email" autocomplete="off" placeholder="name@gmail.com" />' +
        '<div class="smp-em-err" id="smpEmErr"></div>' +
        '<div class="smp-em-actions">' +
          (required ? '' : '<button type="button" id="smpEmSkip">Cancel</button>') +
          '<button type="button" id="smpEmSave" class="smp-em-primary">Save</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(o);
    var a = document.getElementById("smpEmA"), b = document.getElementById("smpEmB");
    var err = document.getElementById("smpEmErr"), save = document.getElementById("smpEmSave"), skip = document.getElementById("smpEmSkip");
    var busy = false;
    if(current) a.value = current;
    a.focus();
    function close(){ if(!busy) o.remove(); }
    if(skip) skip.addEventListener("click", close);
    async function submit(){
      if(busy) return;
      var v = (a.value || "").trim().toLowerCase(), c = (b.value || "").trim().toLowerCase();
      if(!GMAIL_RE.test(v)){ err.textContent = "Please enter a valid Gmail address (name@gmail.com)."; return; }
      if(v !== c){ err.textContent = "The two addresses don't match - check for typos."; return; }
      err.textContent = ""; busy = true; save.disabled = true; if(skip) skip.disabled = true; save.textContent = "Saving…";
      try{
        var res = await sb.rpc("fn_set_my_notify_email", { p_email: v });
        if(res.error) throw res.error;
        try{ sessionStorage.setItem(ASKED_KEY, "1"); }catch(e){}
        busy = false; o.remove();
        say("Gmail address saved: " + v);
      }catch(e2){
        busy = false; save.disabled = false; if(skip) skip.disabled = false; save.textContent = "Save";
        err.textContent = (e2 && e2.message) || "Could not save. Please try again.";
      }
    }
    save.addEventListener("click", submit);
    [a, b].forEach(function(el){ el.addEventListener("keydown", function(e){ if(e.key === "Enter"){ e.preventDefault(); submit(); } }); });
  }

  async function currentEmail(){
    var res = await sb.rpc("fn_my_notify_email");
    if(res.error) throw res.error;
    return res.data || "";
  }

  async function firstPagePrompt(){
    try{
      if(sessionStorage.getItem(ASKED_KEY)) return;
      var cur = await currentEmail();
      if(cur){ try{ sessionStorage.setItem(ASKED_KEY, "1"); }catch(e){} return; }   // has one: stop checking this session
      openModal("", true);                                                           // none yet: ask on every page until saved
    }catch(e){ /* never block the page over this */ }
  }

  function injectButton(){
    var who = document.getElementById("whoBox");
    if(!who || document.getElementById("emailBtn")) return;
    var btn = document.createElement("button");
    btn.type = "button"; btn.id = "emailBtn";
    btn.className = "btn-secondary sync-me-btn";
    btn.title = "Set or change the Gmail address that reports are sent to";
    btn.innerHTML = "&#9993; Email";
    who.parentNode.insertBefore(btn, who);
    btn.addEventListener("click", async function(){
      try{ openModal(await currentEmail(), false); }catch(e){ say("Could not load your email: " + ((e && e.message) || "error"), true); }
    });
  }

  var tries = 0;
  var timer = setInterval(function(){
    tries++;
    if(ready()){ clearInterval(timer); injectButton(); firstPagePrompt(); }
    else if(tries > 50){ clearInterval(timer); }   // ~20 s: not signed in / page without a profile
  }, 400);
})();
