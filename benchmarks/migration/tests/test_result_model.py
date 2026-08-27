import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "benchmarks" / "migration" / "scripts"))

from result_model import coefficient_of_variation, compare, median_metrics


METRICS = {
    "throughput_mbps": 100.0,
    "packet_loss": 0.0,
    "cpu_percent": 20.0,
    "peak_rss_bytes": 100_000_000.0,
    "latency_ms": 120.0,
    "startup_ms": 500.0,
    "failover_gap_ms": 250.0,
}


class ResultModelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        threshold_path = ROOT / "benchmarks" / "migration" / "thresholds.json"
        cls.thresholds = json.loads(threshold_path.read_text())

    def test_median_metrics_handles_even_and_odd_runs(self):
        runs = []
        for throughput, cpu in [(90.0, 30.0), (110.0, 10.0), (100.0, 20.0)]:
            run = dict(METRICS)
            run["throughput_mbps"] = throughput
            run["cpu_percent"] = cpu
            runs.append(run)

        medians = median_metrics(runs)

        self.assertEqual(medians["throughput_mbps"], 100.0)
        self.assertEqual(medians["cpu_percent"], 20.0)
        self.assertEqual(
            median_metrics(runs[:2])["throughput_mbps"],
            100.0,
        )

    def test_coefficient_of_variation(self):
        self.assertEqual(coefficient_of_variation([]), 0.0)
        self.assertEqual(coefficient_of_variation([4.0]), 0.0)
        self.assertEqual(coefficient_of_variation([0.0, 0.0]), 0.0)
        self.assertAlmostEqual(
            coefficient_of_variation([8.0, 10.0, 12.0]),
            0.163299316,
        )

    def test_compare_passes_values_inside_all_thresholds(self):
        rust = dict(METRICS)
        rust.update(
            throughput_mbps=100.0,
            cpu_percent=21.5,
            peak_rss_bytes=110_000_000.0,
            latency_ms=125.0,
            startup_ms=520.0,
            failover_gap_ms=260.0,
        )

        decision = compare([METRICS] * 3, [rust] * 3, self.thresholds)

        self.assertEqual(decision["status"], "pass")
        self.assertTrue(all(metric["pass"] for metric in decision["metrics"].values()))
        self.assertEqual(decision["reasons"], [])

    def test_compare_reports_regression(self):
        rust = dict(METRICS)
        rust["throughput_mbps"] = 95.0
        rust["cpu_percent"] = 24.0

        decision = compare([METRICS] * 3, [rust] * 3, self.thresholds)

        self.assertEqual(decision["status"], "fail")
        self.assertFalse(decision["metrics"]["throughput_ratio"]["pass"])
        self.assertFalse(decision["metrics"]["cpu_ratio"]["pass"])
        self.assertGreaterEqual(len(decision["reasons"]), 2)

    def test_compare_marks_high_variance_inconclusive(self):
        rust_runs = []
        for throughput in [80.0, 100.0, 120.0]:
            run = dict(METRICS)
            run["throughput_mbps"] = throughput
            rust_runs.append(run)

        decision = compare([METRICS] * 3, rust_runs, self.thresholds)

        self.assertEqual(decision["status"], "inconclusive")
        self.assertTrue(
            any("coefficient of variation" in reason for reason in decision["reasons"])
        )


if __name__ == "__main__":
    unittest.main()
