import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import push_supabase as ps
from smp_extractor.cli import _parse_shard, _read_codes_file, _take_shard, _validate_codes


def make_bundle(root: Path, status="ok") -> Path:
    (root / "csv").mkdir()
    (root / "csv/a_inv.csv").write_text("Date,Inventory Received,Inventory Type,Delivery Challan No,Image\n25-09-2026,345,Milk,D1,\n30-09-2026,230,Biscuits,B9,x\n", encoding="utf-8-sig")
    (root / "csv/a_sum.csv").write_text("Sr#,Date,Received Quantity,Present Stock,Consumption,Remaining Balance\n1,28-09-2026,0,345,112,233\n", encoding="utf-8")
    tables = [
        {"title": "INVENTORY RECEIVING DATA", "csv_file": "csv/a_inv.csv", "complete": True},
        {"title": "SUMMARY DATE WISE (MILK)", "csv_file": "csv/a_sum.csv", "complete": True},
    ]
    manifest = {"results": [{"emis_code": "32230155", "status": status, "tables": tables},
                            {"emis_code": "32230183", "status": "failed", "tables": []}]}
    (root / "run_manifest.json").write_text(json.dumps(manifest))
    return root


class PushTests(unittest.TestCase):
    def test_collect_maps_products_dates_and_skips_failed_schools(self):
        with tempfile.TemporaryDirectory() as d:
            r, c, ok, skipped = ps.collect(make_bundle(Path(d)))
        self.assertEqual(ok, ["32230155"])
        self.assertEqual(skipped, ["32230183"])
        self.assertEqual([(x["product"], x["date"], x["challan"]) for x in r],
                         [("milk", "2026-09-25", "D1"), ("biscuit", "2026-09-30", "B9")])
        self.assertTrue(r[1]["has_image"])
        self.assertEqual((c[0]["product"], c[0]["date"], c[0]["consumption"]), ("milk", "2026-09-28", "112"))

    def test_push_sends_chunks_and_reports_partial(self):
        calls = []
        def fake(url, key, payload, fn="fn_portal_import"):
            if fn == "fn_portal_watermarks":
                return [{"emis": "32230155", "product": "milk", "cons": "2026-09-28", "receipt": "2026-09-25"}]
            calls.append(payload)
            return {"run_id": 7, "receipts": len(payload.get("p_receipts", [])), "consumption": len(payload.get("p_consumption", []))}
        with tempfile.TemporaryDirectory() as d, mock.patch.object(ps, "rpc", fake):
            code = ps.push(make_bundle(Path(d)), "https://x", "k")
        self.assertEqual(code, 1)
        self.assertEqual(calls[-1]["p_run"]["status"], "partial")
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1]["p_run"]["ok_emis"], ["32230155"])
        # milk receipt of 25 Sep is inside the 3-day overlap of the stored 25 Sep, the biscuit one has no mark
        self.assertEqual(len(calls[1]["p_receipts"]), 2)

    def test_watermarks_skip_rows_already_stored(self):
        rows_r = [{"emis": "1", "product": "milk", "date": "2026-09-01"}, {"emis": "1", "product": "milk", "date": "2026-09-20"},
                  {"emis": "1", "product": "biscuit", "date": "2026-01-01"}]
        rows_c = [{"emis": "1", "product": "milk", "date": "2026-09-19"}, {"emis": "1", "product": "milk", "date": "2026-09-21"}]
        marks = [{"emis": "1", "product": "milk", "cons": "2026-09-22", "receipt": "2026-09-22"}]
        r, c = ps.apply_watermarks(rows_r, rows_c, marks, 3)
        self.assertEqual([x["date"] for x in r], ["2026-09-20", "2026-01-01"])
        self.assertEqual([x["date"] for x in c], ["2026-09-21"])

    def test_dry_run_needs_no_credentials(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(ps.main(["--bundle", str(make_bundle(Path(d))), "--dry-run"]), 0)


class ScopeTests(unittest.TestCase):
    def test_codes_file_and_shards(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "c.txt"
            f.write_text("# karor\n32220001\n32220002, 32220003  # x\n32220001\n")
            codes = _read_codes_file(f)
        self.assertEqual(codes, ["32220001", "32220002", "32220003"])
        self.assertEqual(_validate_codes(codes, codes), codes)
        self.assertEqual(_take_shard(codes, _parse_shard("2/2")), ["32220002"])
        with self.assertRaises(ValueError):
            _parse_shard("3/2")
        with self.assertRaises(ValueError):
            _validate_codes(["99999999"], codes)


if __name__ == "__main__":
    unittest.main()
