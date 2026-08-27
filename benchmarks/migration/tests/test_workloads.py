import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKLOAD_DIR = ROOT / "benchmarks" / "migration" / "workloads"
REQUIRED_IDS = {
    "srt-1080p25-5m",
    "srt-1080p50-25m",
    "srt-three-destinations",
    "udp-to-srt",
    "dual-ingest-failover",
    "srt-thumbnail",
    "non-sdi-soak",
}
REQUIRED_METRICS = {
    "throughput_mbps",
    "packet_loss",
    "cpu_percent",
    "peak_rss_bytes",
    "latency_ms",
    "startup_ms",
    "failover_gap_ms",
}


class WorkloadContractTest(unittest.TestCase):
    def load_workloads(self):
        return [json.loads(path.read_text()) for path in sorted(WORKLOAD_DIR.glob("*.json"))]

    def test_required_workload_ids_are_unique_and_complete(self):
        workloads = self.load_workloads()
        ids = [workload["id"] for workload in workloads]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(set(ids), REQUIRED_IDS)

    def test_schema_and_timing_contract(self):
        for workload in self.load_workloads():
            with self.subTest(workload=workload["id"]):
                self.assertIn(workload["source"]["protocol"], {"srt", "udp"})
                self.assertTrue(workload["destinations"])
                self.assertTrue(
                    all(
                        destination["protocol"] in {"srt", "udp"}
                        for destination in workload["destinations"]
                    )
                )
                self.assertGreater(workload["video"]["width"], 0)
                self.assertGreater(workload["video"]["height"], 0)
                self.assertGreater(workload["video"]["fps_num"], 0)
                self.assertGreater(workload["video"]["fps_den"], 0)
                self.assertGreater(workload["video"]["bitrate_mbps"], 0)
                self.assertEqual(set(workload["metrics"]), REQUIRED_METRICS)

                timing = workload["timing"]
                if workload["id"] == "non-sdi-soak":
                    self.assertEqual(timing["warmup_seconds"], 0)
                    self.assertEqual(timing["measurement_seconds"], 3600)
                    self.assertEqual(timing["repetitions"], 1)
                else:
                    self.assertEqual(timing["warmup_seconds"], 30)
                    self.assertEqual(timing["measurement_seconds"], 120)
                    self.assertEqual(timing["repetitions"], 3)

    def test_three_destination_and_failover_scenarios(self):
        workloads = {item["id"]: item for item in self.load_workloads()}
        three = workloads["srt-three-destinations"]
        destination_modes = [
            (destination["protocol"], destination["mode"])
            for destination in three["destinations"]
        ]
        self.assertEqual(
            destination_modes,
            [("srt", "caller"), ("srt", "listener"), ("udp", "sink")],
        )

        failover = workloads["dual-ingest-failover"]
        self.assertEqual(failover["secondary_source"]["protocol"], "srt")
        self.assertEqual(
            failover["events"],
            [
                {"at_second": 60, "command": "switch-source", "target": "secondary"},
                {"at_second": 90, "command": "switch-source", "target": "primary"},
            ],
        )

    def test_benchmark_image_is_noble_and_self_contained(self):
        dockerfile = ROOT / "benchmarks" / "migration" / "Dockerfile.ubuntu-24.04"
        text = dockerfile.read_text()
        self.assertTrue(text.startswith("FROM ubuntu:24.04"))
        for required in (
            "build-essential",
            "libgstreamer1.0-dev",
            "libgstreamer-plugins-base1.0-dev",
            "gstreamer1.0-plugins-good",
            "gstreamer1.0-plugins-bad",
            "libsrt-gnutls-dev",
            "ffmpeg",
            "python3",
            "procps",
            "sysstat",
            "rustup",
            "native/archive/c-engine",
            "native/rust",
            "benchmarks/migration",
        ):
            self.assertIn(required, text)
        for forbidden in ("COPY .env", "COPY config/runtime.exs", "COPY /root"):
            self.assertNotIn(forbidden, text)

        runtime_stage = text.split("FROM ubuntu:24.04", 2)[2]
        self.assertLess(
            runtime_stage.index("rm -rf /var/lib/apt/lists/*"),
            runtime_stage.index("BLACKGATE_BENCH_GIT_COMMIT"),
        )


if __name__ == "__main__":
    unittest.main()
