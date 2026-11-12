"""Push an export bundle straight into Supabase (table data only, nothing is committed).

Reads <bundle>/run_manifest.json and the CSV files it points at, and sends receipts
(INVENTORY RECEIVING DATA) and the per-day stock/consumption summaries (SUMMARY DATE WISE)
to the ``fn_portal_import`` function using the service-role key.

Environment: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. Neither is ever printed.
Only schools whose status is "ok" are pushed; the exit code is 1 if any school was skipped.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BISCUIT = {"biscuit", "biscuits"}
CHUNK_SCHOOLS = 10


def portal_date(text: str) -> str:
    day, month, year = text.strip().split("-")
    return dt.date(int(year), int(month), int(day)).isoformat()


def _rows(bundle: Path, table: dict[str, Any]) -> list[dict[str, str]]:
    path = bundle / (table.get("csv_file") or "")
    if not path.is_file():
        raise FileNotFoundError(f"missing CSV {table.get('csv_file')}")
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        return [{k.strip(): (v or "").strip() for k, v in r.items() if k} for r in csv.DictReader(fh)]


def _product(kind: str) -> str:
    return "biscuit" if kind.strip().lower() in BISCUIT else "milk"


def collect(bundle: Path) -> tuple[list[dict], list[dict], list[str], list[str]]:
    """Return (receipts, consumption, ok_codes, skipped_codes)."""
    manifest = json.loads((bundle / "run_manifest.json").read_text(encoding="utf-8"))
    receipts: list[dict] = []
    cons: list[dict] = []
    ok: list[str] = []
    skipped: list[str] = []
    for result in manifest.get("results", []):
        emis = str(result.get("emis_code"))
        tables = result.get("tables", [])
        if result.get("status") != "ok" or any(t.get("complete") is False for t in tables):
            skipped.append(emis)
            continue
        for table in tables:
            title = str(table.get("title") or "").strip().upper()
            if title == "INVENTORY RECEIVING DATA":
                for r in _rows(bundle, table):
                    if not r.get("Date"):
                        continue
                    receipts.append({
                        "emis": emis, "product": _product(r.get("Inventory Type", "")),
                        "date": portal_date(r["Date"]), "qty": r.get("Inventory Received", ""),
                        "challan": r.get("Delivery Challan No", ""), "has_image": bool(r.get("Image")),
                    })
            elif title.startswith("SUMMARY DATE WISE"):
                product = "biscuit" if "BISCUIT" in title else "milk"
                for r in _rows(bundle, table):
                    if not r.get("Date"):
                        continue
                    cons.append({
                        "emis": emis, "product": product, "date": portal_date(r["Date"]),
                        "received": r.get("Received Quantity", ""), "present": r.get("Present Stock", ""),
                        "consumption": r.get("Consumption", ""), "remaining": r.get("Remaining Balance", ""),
                    })
        ok.append(emis)
    return receipts, cons, ok, skipped


def rpc(url: str, key: str, payload: dict, fn: str = "fn_portal_import"):
    req = urllib.request.Request(
        url.rstrip("/") + "/rest/v1/rpc/" + fn,
        data=json.dumps(payload).encode(),
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:  # never echo request data or headers
        raise RuntimeError(f"Supabase answered HTTP {exc.code}: {exc.read().decode()[:300]}") from None


def apply_watermarks(receipts: list[dict], cons: list[dict], marks: list[dict], overlap_days: int) -> tuple[list[dict], list[dict]]:
    """Drop rows the database already has. Keeps the last ``overlap_days`` days so late edits on the portal are picked up."""
    cut = dt.timedelta(days=overlap_days)
    lc = {(m["emis"], m["product"]): dt.date.fromisoformat(m["cons"]) for m in marks if m.get("cons")}
    lr = {(m["emis"], m["product"]): dt.date.fromisoformat(m["receipt"]) for m in marks if m.get("receipt")}

    def fresh(row: dict, table: dict) -> bool:
        mark = table.get((row["emis"], row["product"]))
        return mark is None or dt.date.fromisoformat(row["date"]) > mark - cut

    return [r for r in receipts if fresh(r, lr)], [c for c in cons if fresh(c, lc)]


def push(bundle: Path, url: str, key: str, shard: str = "", overlap_days: int = 3, full: bool = False) -> int:
    receipts, cons, ok, skipped = collect(bundle)
    total_r, total_c = len(receipts), len(cons)
    if not full:
        marks = rpc(url, key, {}, "fn_portal_watermarks")
        receipts, cons = apply_watermarks(receipts, cons, marks, overlap_days)
        print(f"Already in Supabase: skipped {total_r - len(receipts)} receipt row(s) and {total_c - len(cons)} stock-day row(s).")
    run = rpc(url, key, {"p_run": {"shard": shard or None, "schools_total": len(ok) + len(skipped)}})["run_id"]
    sent_r = sent_c = 0
    for i in range(0, len(ok), CHUNK_SCHOOLS):
        group = set(ok[i : i + CHUNK_SCHOOLS])
        res = rpc(url, key, {
            "p_run": {"run_id": run, "ok_emis": sorted(group)},
            "p_receipts": [r for r in receipts if r["emis"] in group],
            "p_consumption": [c for c in cons if c["emis"] in group],
        })
        sent_r += res.get("receipts", 0)
        sent_c += res.get("consumption", 0)
    note = f"skipped (incomplete): {', '.join(skipped)}" if skipped else None
    rpc(url, key, {"p_run": {"run_id": run, "finish": True, "schools_ok": len(ok), "note": note,
                              "status": "done" if not skipped else "partial"}})
    print(f"Pushed run {run}: {len(ok)} school(s), {sent_r} receipt row(s), {sent_c} stock-day row(s).")
    if skipped:
        print(f"Not pushed (incomplete or failed): {', '.join(skipped)}", file=sys.stderr)
    return 1 if skipped else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bundle", type=Path, required=True, help="Bundle folder containing run_manifest.json")
    ap.add_argument("--shard", default="", help="Label stored with the run, e.g. 1/3")
    ap.add_argument("--overlap-days", type=int, default=3, help="Re-send this many days before the last stored date (default 3).")
    ap.add_argument("--full", action="store_true", help="Ignore the stored position and send everything.")
    ap.add_argument("--dry-run", action="store_true", help="Parse and count only; do not contact Supabase.")
    args = ap.parse_args(argv)
    bundle = args.bundle
    if not (bundle / "run_manifest.json").is_file():  # allow the parent folder of timestamped bundles
        found = sorted(p for p in bundle.glob("*/run_manifest.json"))
        if not found:
            ap.error(f"no run_manifest.json under {bundle}")
        bundle = found[-1].parent
    if args.dry_run:
        r, c, ok, sk = collect(bundle)
        print(f"Dry run: {len(ok)} ok, {len(sk)} skipped, {len(r)} receipt row(s), {len(c)} stock-day row(s).")
        return 0
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        print("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.", file=sys.stderr)
        return 2
    return push(bundle, url, key, args.shard, args.overlap_days, args.full)


if __name__ == "__main__":
    raise SystemExit(main())
