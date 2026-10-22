// Period locks (set by the Admin): tells the pages which product / entry type / dates are locked, so they can show a
// lock indicator and stop the user before a save. The DATABASE is what actually enforces a lock - this file only
// explains it. It also reports refused attempts (best effort: a refused write is rolled back by the database, so
// the database cannot record the attempt itself).
(function(){
  var locks = [], loaded = null, recent = {};

  function pretty(d){
    if(!d) return "";
    var p = String(d).split("-").map(Number);
    return new Date(Date.UTC(p[0], p[1] - 1, p[2])).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
  }
  function logAttempt(table, op, productId, type, dateStr){
    try{
      if(typeof sb === "undefined" || !productId || !type || !dateStr) return;
      var k = [table, op, productId, type, dateStr].join("|"), now = Date.now();
      if(recent[k] && now - recent[k] < 5000) return;      // one record per burst
      recent[k] = now;
      sb.rpc("fn_log_lock_attempt", { p_table: table, p_operation: op, p_product: productId, p_entry_type: type, p_entry_date: dateStr }).then(function(){}, function(){});
    }catch(e){}
  }

  window.smpLocks = {
    load: function(force){
      if(loaded && !force) return loaded;
      loaded = (async function(){
        try{
          if(typeof sb === "undefined") return;
          var res = await sb.rpc("fn_period_lock_status");
          if(!res.error && res.data) locks = res.data.filter(function(l){ return l.status === "locked"; });
        }catch(e){}
      })();
      return loaded;
    },
    // Locked-through date (YYYY-MM-DD) when this product / entry type / date is inside a locked period, else null.
    through: function(productId, type, dateStr){
      for(var i = 0; i < locks.length; i++){
        var l = locks[i];
        if(l.product_id === productId && l.entry_type === type && dateStr && String(dateStr) <= l.locked_through) return l.locked_through;
      }
      return null;
    },
    pretty: pretty,
    // The locked-through date of a product's lock (any date), or null when that product/entry type isn't locked.
    lockedThrough: function(productId, type){
      for(var i = 0; i < locks.length; i++){
        if(locks[i].product_id === productId && locks[i].entry_type === type) return locks[i].locked_through;
      }
      return null;
    },
    dayAfter: function(d){
      var p = String(d).split("-").map(Number), x = new Date(Date.UTC(p[0], p[1] - 1, p[2] + 1));
      return x.toISOString().slice(0, 10);
    },
    message: function(productName, type, through){
      return "This product's (" + (productName || "product") + ") " + type + " period is locked by the Admin through " + pretty(through) + ". Please contact the Admin for corrections.";
    },
    logAttempt: logAttempt
  };

  // Any page that gets the database's lock refusal (code SMLCK) reports it once, whichever screen or button caused it.
  try{
    var origFetch = window.fetch;
    if(origFetch){
      window.fetch = function(){
        var p = origFetch.apply(this, arguments);
        try{
          p.then(function(res){
            if(res && res.status === 400){
              res.clone().json().then(function(b){
                if(b && b.code === "SMLCK" && b.details){
                  try{ var d = JSON.parse(b.details); logAttempt(d.table, d.operation, d.product_id, d.entry_type, d.entry_date); }catch(e){}
                }
              }).catch(function(){});
            }
          }).catch(function(){});
        }catch(e){}
        return p;
      };
    }
  }catch(e){}
})();
