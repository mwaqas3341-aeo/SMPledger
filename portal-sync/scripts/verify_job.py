"""Re-check on the SMP dashboard the schools listed in a WhatsApp missing-consumption report, just before it is sent.

  python scripts/verify_job.py gate                 prints run=true/false (and id=N) for GITHUB_OUTPUT
  python scripts/verify_job.py codes N FILE         writes the EMIS codes of request N, one per line
  python scripts/verify_job.py finish N ok|fail     closes request N; Supabase then rebuilds and queues the report(s)

Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment (never printed). Any error in `gate` means run=false.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def rpc(fn: str, payload: dict):
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.")
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/rpc/" + fn, data=json.dumps(payload).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Supabase answered HTTP {exc.code}: {exc.read().decode()[:200]}") from None


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "gate":
        try:
            ans = rpc("fn_wa_smp_verify_gate", {})
        except Exception as exc:  # noqa: BLE001 - any failure just means "not now"
            print(f"::warning::Verify gate failed ({type(exc).__name__}: {exc}); will ask again at the next tick.", file=sys.stderr)
            print("run=false")
            return 0
        print(f"Re-check request: {ans}", file=sys.stderr)
        if ans.get("run"):
            print("run=true")
            print(f"id={int(ans['id'])}")
        else:
            print("run=false")
        return 0
    if cmd == "codes" and len(argv) == 3:
        codes = [c for c in (rpc("fn_wa_smp_verify_codes", {"p_id": int(argv[1])}) or []) if isinstance(c, str) and c.isdigit() and len(c) == 8]
        if not codes:
            print("No schools to re-check.", file=sys.stderr)
            return 1
        Path(argv[2]).write_text("\n".join(codes) + "\n", encoding="utf-8")
        print(f"{len(codes)} school(s) to re-check.")
        return 0
    if cmd == "finish" and len(argv) == 3 and argv[2] in ("ok", "fail"):
        rpc("fn_wa_smp_verify_finish", {"p_id": int(argv[1]), "p_ok": argv[2] == "ok", "p_note": None})
        print(f"Request {argv[1]} closed ({argv[2]}).")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
