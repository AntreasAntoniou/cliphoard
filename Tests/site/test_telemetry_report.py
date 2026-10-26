import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("report", Path(__file__).resolve().parents[2] / "Scripts/telemetry-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

class ReportTests(unittest.TestCase):
    def test_latest_snapshot_replaces_symlink_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "original.html"
            original.write_text("retained snapshot")
            latest = root / "latest.html"
            latest.symlink_to(original)
            report.replace_private(latest, "new snapshot")
            self.assertEqual(original.read_text(), "retained snapshot")
            self.assertFalse(latest.is_symlink())
            self.assertEqual(latest.read_text(), "new snapshot")
            self.assertEqual(latest.stat().st_mode & 0o777, 0o600)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ["latest.html", "original.html"])

    def test_downloads_exclude_checksums_models_drafts_and_prereleases(self):
        asset = {"name": "Cliphoard-1.0.2.dmg", "download_count": 28, "id": 1}
        rows = [{"tag_name": "v1.0.2", "assets": [asset, {"name": "SHA256SUMS.txt", "download_count": 9}]},
                {"tag_name": "model", "prerelease": True, "assets": [asset]},
                {"tag_name": "draft", "draft": True, "assets": [asset]}]
        self.assertEqual(report.release_rows(rows), [{"release": "v1.0.2", "asset": asset["name"], "asset_id": 1, "downloads": 28}])

    def test_sampling_weights_and_bounded_range_are_explicit(self):
        query = report.event_query(30)
        self.assertIn("SUM(_sample_interval * double1)", query)
        self.assertIn("LIMIT 10000", query)
        for bad in (0, 91, "1; DROP TABLE"):
            with self.assertRaises(report.ReportError):
                report.event_query(bad)

    def test_live_dashboard_excludes_test_and_qa_from_sales(self):
        rows = [{"surface": "commerce", "mode": m, "event": "licence_issued", "placement": "order", "events": n}
                for m, n in [("live", 2), ("test", 40), ("qa", 50)]]
        self.assertEqual(report.totals(rows)[("commerce", "licence_issued", "order")], 2)

    def test_unavailable_is_not_zero_and_untrusted_text_is_escaped(self):
        value = {"generated_at": "<script>bad</script>", "days": 30,
                 "analytics": {"status": "unavailable"}, "downloads": {"status": "unavailable"}}
        value["alerts"] = report.alerts(value)
        page = report.dashboard(value)
        self.assertIn("Unavailable", page)
        self.assertIn("&lt;script&gt;bad&lt;/script&gt;", page)
        self.assertNotIn("<script>", page)
        self.assertIn("not unique visitors", page)
        self.assertIn("inbox arrival not established", page)

    def test_only_live_operational_failures_raise_alerts(self):
        row = {"surface": "commerce", "mode": "test", "event": "email_exhausted", "placement": "order", "events": 3}
        value = {"analytics": {"status": "available", "rows": [row]}, "downloads": {"status": "available"}}
        self.assertEqual(report.alerts(value), [])
        row["mode"] = "live"
        self.assertEqual(len(report.alerts(value)), 1)

if __name__ == "__main__":
    unittest.main()
