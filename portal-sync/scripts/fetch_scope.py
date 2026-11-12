"""Write the list of schools to sync (one EMIS per line) from Supabase.

The list comes from fn_portal_scope(), which uses the portal_sync_settings row (default: tehsil KAROR LALISAN,
wing M-EE, active schools). Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment.
Usage: python scripts/fetch_scope.py codes.txt
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fetch(url: str, key: str) -> list[str]:
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/rpc/fn_portal_scope", data=b"{}", method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            codes = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Supabase answered HTTP {exc.code}: {exc.read().decode()[:200]}") from None
    return [c for c in codes if isinstance(c, str) and c.isdigit() and len(c) == 8]


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.", file=sys.stderr)
        return 2
    codes = fetch(url, key)
    if not codes:
        print("Supabase returned no schools in scope.", file=sys.stderr)
        return 1
    Path(args[0]).write_text("\n".join(codes) + "\n", encoding="utf-8")
    print(f"{len(codes)} school(s) in scope.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
