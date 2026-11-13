import sys
import types
import unittest
from unittest import mock

from smp_extractor import collector
from smp_extractor.collector import AuthenticationError


class FakePage:
    def set_default_timeout(self, *_): pass


class FakeContext:
    def new_page(self): return FakePage()
    def close(self): pass


class FakeBrowser:
    def new_context(self): return FakeContext()
    def close(self): pass


class FakePlaywright:
    chromium = types.SimpleNamespace(launch=lambda headless=True: FakeBrowser())
    def __enter__(self): return self
    def __exit__(self, *a): return False


def run(codes, extract, **kw):
    fake = types.ModuleType("playwright.sync_api")
    fake.sync_playwright = lambda: FakePlaywright()
    pkg = types.ModuleType("playwright")
    with mock.patch.dict(sys.modules, {"playwright": pkg, "playwright.sync_api": fake}), \
         mock.patch.object(collector, "_ensure_authenticated"), \
         mock.patch.object(collector, "_extract_school", side_effect=extract), \
         mock.patch.object(collector.time, "sleep"):
        return collector.extract_schools("https://x", codes, delay_seconds=0, non_interactive=True, **kw)


def ok(page, result, *_): result.status = "ok"


class SafeguardTests(unittest.TestCase):
    def test_stops_after_consecutive_errors_and_keeps_earlier_schools(self):
        def extract(page, result, *_):
            if result.emis_code == "1": result.status = "ok"
            else: raise ValueError("boom")
        out = run([str(i) for i in range(1, 12)], extract, max_consecutive_errors=3)
        self.assertEqual([r.status for r in out[:4]], ["ok", "error", "error", "error"])
        self.assertTrue(all(r.status == "skipped" for r in out[4:]))

    def test_session_loss_is_recovered_once_per_school(self):
        calls = {"n": 0}
        def extract(page, result, *_):
            calls["n"] += 1
            if calls["n"] == 2: raise AuthenticationError("logged out")
            result.status = "ok"
        out = run(["1", "2", "3"], extract)
        self.assertEqual([r.status for r in out], ["ok", "ok", "ok"])

    def test_deadline_skips_remaining(self):
        ticks = iter([0, 0, 10, 100, 200, 300, 400])
        with mock.patch.object(collector.time, "monotonic", side_effect=lambda: next(ticks)):
            out = run(["1", "2", "3", "4"], ok, deadline_seconds=50)
        self.assertIn("skipped", [r.status for r in out])
        self.assertEqual(out[0].status, "ok")


if __name__ == "__main__":
    unittest.main()
