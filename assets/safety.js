// Global crash guard: any uncaught error or rejected promise shows a dismissible
// banner instead of leaving the page blank. Logs are console-only and never include
// tokens or user data.
(function(){
  var shown = 0;
  function banner(msg){
    try{
      if(shown >= 3) return; shown++;
      var d = document.createElement("div");
      d.setAttribute("role","alert");
      d.style.cssText = "position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:9999;max-width:92vw;background:#fdecea;color:#8a1f17;border:1px solid #f5c2be;padding:10px 14px;border-radius:8px;font:13px system-ui,sans-serif;box-shadow:0 4px 14px rgba(0,0,0,.12)";
      d.innerHTML = "Something went wrong loading part of this page. <a href='' style='color:#8a1f17;font-weight:600'>Reload</a> <button type='button' style='margin-left:8px;border:0;background:transparent;cursor:pointer;font-size:16px;color:#8a1f17' aria-label='Dismiss'>&times;</button>";
      d.querySelector("button").onclick = function(){ d.remove(); shown--; };
      (document.body || document.documentElement).appendChild(d);
    }catch(e){}
  }
  window.addEventListener("error", function(e){ console.error("[SMP] error:", e && e.message); banner(); });
  window.addEventListener("unhandledrejection", function(e){
    var r = e && e.reason; console.error("[SMP] unhandled rejection:", r && r.message ? r.message : "unknown"); banner();
  });
})();
