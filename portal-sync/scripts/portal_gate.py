"""Ask Supabase whether today's sync should start now (one run a day, at a random time 04:00-05:15 Pakistan time).

Prints "run=true" or "run=false" (for GITHUB_OUTPUT). Any error means "run=false": the schedule asks again 15 minutes later.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def ask(url: str, key: str) -> dict:
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/rpc/fn_portal_gate", data=b"{}", method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main() -> int:
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("::warning::Supabase secrets are missing.", file=sys.stderr)
        print("run=false")
        return 0
    try:
        answer = ask(url, key)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        print(f"::warning::Gate check failed ({type(exc).__name__}); will ask again at the next tick.", file=sys.stderr)
        print("run=false")
        return 0
    print(f"Planned start: {answer.get('planned_at')}; start now: {answer.get('run')}", file=sys.stderr)
    print("run=true" if answer.get("run") else "run=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
