"""Unit and real-filesystem integration checks for the Pages artifact."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("build_site", Path(__file__).with_name("build-site.py"))
SITE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SITE)


class ReportTests(unittest.TestCase):
    def test_numeric_measurements(self):
        self.assertEqual(SITE.number("569,114.73"), 569114.73)
        self.assertEqual(SITE.number("114.182 ms"), 114.182)
        with self.assertRaises(ValueError):
            SITE.number("unknown")

    def test_latest_aws_data_and_capacity(self):
        run = SITE.parse_report(SITE.ROOT / "benchmarks/runs/20261001T205742Z.md", "aws")
        self.assertEqual(len(run["points"]), 8)
        peak = max(run["points"], key=lambda point: point["rps"])
        self.assertEqual(peak["rps"], 569114.73)
        self.assertEqual(peak["connections"], 4096)
        self.assertEqual((peak["tasks"], peak["hosts"], peak["p99"]), (8, 2, 54.607))
        self.assertEqual(run["environment"], "AWS · ALB interno")

    def test_direct_ramp_and_endpoint_tables(self):
        ramp = SITE.parse_report(SITE.ROOT / "benchmarks/runs/20260928T163422Z.md", "aws")
        self.assertEqual(ramp["points"][-1]["connections"], 1024)
        self.assertEqual(ramp["points"][-1]["tasks"], 1)
        self.assertEqual(ramp["environment"], "AWS · IP direto")
        hey = SITE.parse_report(SITE.ROOT / "benchmarks/runs/20260928T032108Z.md", "aws")
        self.assertTrue(hey["sampled"])
        self.assertEqual(hey["points"][1]["endpoint"], "/spots")
        self.assertEqual(hey["points"][1]["connections"], 64)
        self.assertEqual(hey["points"][1]["errors"], 0)

    def test_interrupted_attempt_is_excluded(self):
        self.assertIsNone(SITE.parse_report(SITE.ROOT / "benchmarks/runs/20260929T221924Z.md", "aws"))

    def test_local_medians_not_invented_percentiles(self):
        run = SITE.parse_report(SITE.ROOT / "benchmarks/local/20261001T144339Z.md", "local")
        self.assertEqual(run["environment"], "Local · nativo")
        self.assertEqual(run["points"][0]["gomaxprocs"], "8")
        self.assertIsNone(run["points"][0]["p50"])
        self.assertIsNone(run["points"][0]["tasks"])
        self.assertEqual(run["points"][0]["p95"], 0.68)
        docker = SITE.parse_report(SITE.ROOT / "benchmarks/local/20260929T165002Z.md", "local")
        self.assertEqual(docker["environment"], "Local · Docker")

    def test_malformed_table_rejected(self):
        with self.assertRaises(ValueError):
            list(SITE.tables("| A | B |\n|---|---|\n| 1 |"))

    def test_missing_measurements_and_concurrency_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.md"
            path.write_text("# Complete benchmark\n")
            with self.assertRaises(ValueError):
                SITE.parse_report(path, "aws")
            path.write_text("# Benchmark\n| RPS | p95 | p99 |\n|---|---|---|\n| 1 | 1 | 1 |")
            with self.assertRaises(ValueError):
                SITE.parse_report(path, "aws")

    def test_real_build_is_deterministic_and_contains_no_raw_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            SITE.build(SITE.ROOT, output)
            first = (output / "data.json").read_text()
            SITE.build(SITE.ROOT, output)
            self.assertEqual(first, (output / "data.json").read_text())
            data = json.loads(first)
            self.assertGreaterEqual(len(data["runs"]), 20)
            self.assertNotIn("20260929T221924Z", first)
            for sensitive in ("376101301076", ".dkr.ecr.", "app-logs", "results/", "CloudWatch group", "bpftrace"):
                self.assertNotIn(sensitive, first)
            self.assertEqual({p.name for p in output.iterdir()}, {"index.html", "app.js", "style.css", "data.json", ".nojekyll"})
            for run in data["runs"]:
                self.assertTrue(run["points"])
                self.assertTrue(run["source"].startswith(SITE.REPOSITORY))

    def test_empty_repository_fails_build(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            SITE.build(Path(directory), Path(directory) / "public")


if __name__ == "__main__":
    unittest.main()
