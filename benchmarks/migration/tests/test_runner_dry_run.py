import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "benchmarks" / "migration" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from run_benchmark import (
    RunnerError,
    _metadata,
    _metrics_from_evidence,
    _timing,
    build_plan,
    parse_args,
    run_engine_lifecycle,
)
from render_report import render_report


WORKLOAD_PATH = (
    ROOT / "benchmarks" / "migration" / "workloads" / "srt-1080p25-5m.json"
)


class RunnerDryRunTest(unittest.TestCase):
    def test_repetitions_override_supports_inconclusive_reruns(self):
        workload = json.loads(WORKLOAD_PATH.read_text())

        self.assertEqual(_timing(workload, False, 7), (30.0, 120.0, 7))

    def test_quick_rejects_repetitions_override(self):
        with self.assertRaises(SystemExit):
            parse_args(
                [
                    "--c-engine",
                    "c-engine",
                    "--rust-engine",
                    "rust-engine",
                    "--workload",
                    str(WORKLOAD_PATH),
                    "--output",
                    "results",
                    "--quick",
                    "--repetitions",
                    "7",
                ]
            )

    def test_metadata_accepts_baked_build_identity(self):
        with patch.dict(
            os.environ,
            {
                "BLACKGATE_BENCH_GIT_COMMIT": "abc123",
                "BLACKGATE_BENCH_RUST_VERSION": "rustc 1.96.0",
            },
        ):
            metadata = _metadata("start", "finish")

        self.assertEqual(metadata["git_commit"], "abc123")
        self.assertEqual(metadata["rust"], "rustc 1.96.0")

    def test_throughput_uses_media_rate_not_srt_capacity(self):
        stats = [
            {
                "source": "primary",
                "receive-rate-mbps": 10.0,
                "bandwidth-mbps": 900.0,
            },
            {
                "sink-index": 0,
                "send-rate-mbps": 9.8,
                "bandwidth-mbps": 1_200.0,
            },
            {
                "source": "primary",
                "receive-rate-mbps": 0.0,
                "bandwidth-mbps": 0.0,
            },
        ]

        metrics = _metrics_from_evidence(stats, 0.0, 0.0, 1.0, 1, 1.0, [])

        self.assertEqual(metrics["throughput_mbps"], 10.0)

    def test_udp_throughput_falls_back_to_positive_sink_send_rate(self):
        stats = [
            {"source": "primary", "receive-rate-mbps": 0.0},
            {"sink-index": 0, "send-rate-mbps": 9.5},
            {"sink-index": 0, "send-rate-mbps": 9.7},
            {"sink-index": 0, "send-rate-mbps": 0.0},
        ]

        metrics = _metrics_from_evidence(stats, 0.0, 0.0, 1.0, 1, 1.0, [])

        self.assertEqual(metrics["throughput_mbps"], 9.6)

    def make_engine(self, directory: Path, *, fail=False) -> Path:
        engine = directory / ("fail-engine.py" if fail else "fake-engine.py")
        source = """
            #!/usr/bin/env python3
            import json
            import os
            import socket
            import sys

            if FAIL:
                sys.exit(23)
            route_id = sys.argv[1]
            stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            stream.connect(os.environ["BLACKGATE_BENCH_SOCKET"])
            stream.sendall(("route_id:" + route_id).encode())
            init = json.loads(sys.stdin.readline())
            print("Pipeline state changed from READY to PLAYING", flush=True)
            stream.sendall((json.dumps({
                "source": "primary",
                "receive-rate-mbps": 5.0,
                "packets-received": 1000,
                "packets-received-lost": 0,
                "rtt-ms": 10.0
            }) + "\\n").encode())
            while True:
                command = json.loads(sys.stdin.readline())
                if command.get("command") == "stop-route":
                    print("Socket closed.", flush=True)
                    break
            stream.close()
        """.replace("FAIL", "True" if fail else "False")
        engine.write_text(textwrap.dedent(source).lstrip())
        engine.chmod(engine.stat().st_mode | stat.S_IXUSR)
        return engine

    def test_build_plan_contains_receiver_engine_and_sender(self):
        workload = json.loads(WORKLOAD_PATH.read_text())
        plan = build_plan(Path("/opt/engine"), workload, [20001, 20002])

        self.assertEqual(plan["engine"][0], "/opt/engine")
        self.assertIn("ffmpeg", plan["sender"][0])
        self.assertIn("ffmpeg", plan["receivers"][0][0])
        self.assertEqual(plan["route_id"], "bench-srt-1080p25-5m")

    def test_fake_engine_lifecycle_collects_contract_and_metrics(self):
        workload = json.loads(WORKLOAD_PATH.read_text())
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            engine = self.make_engine(directory)
            result = run_engine_lifecycle(
                "rust",
                engine,
                workload,
                directory / "engine.sock",
                duration_seconds=0.05,
            )

        self.assertEqual(result["engine"], "rust")
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["metrics"]["throughput_mbps"], 5.0)
        self.assertEqual(result["metrics"]["packet_loss"], 0.0)
        self.assertIn("route_id:bench-srt-1080p25-5m", result["socket_frames"])
        self.assertIn("Socket closed.", result["stdout"])

    def test_child_failure_raises_and_leaves_no_socket(self):
        workload = json.loads(WORKLOAD_PATH.read_text())
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            engine = self.make_engine(directory, fail=True)
            socket_path = directory / "engine.sock"
            with self.assertRaises(RunnerError):
                run_engine_lifecycle(
                    "rust",
                    engine,
                    workload,
                    socket_path,
                    duration_seconds=0.01,
                )
            self.assertFalse(socket_path.exists())

    def test_report_renderer_writes_decision_table(self):
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = Path(raw_directory)
            summary = {
                "status": "pass",
                "metadata": {
                    "git_commit": "abc123",
                    "kernel": "Linux test",
                    "cpu": "test-cpu",
                    "rust": "rustc 1.96.0",
                    "ubuntu_image_digest": "sha256:test",
                    "started_at": "2026-08-27T00:00:00Z",
                    "finished_at": "2026-08-27T00:01:00Z",
                },
                "comparisons": [
                    {
                        "workload": "srt-1080p25-5m",
                        "decision": {
                            "status": "pass",
                            "reasons": [],
                            "metrics": {
                                "throughput_ratio": {
                                    "c": 5.0,
                                    "rust": 5.1,
                                    "ratio": 1.02,
                                    "threshold": 0.99,
                                    "operator": ">=",
                                    "pass": True,
                                }
                            },
                        },
                    }
                ],
            }
            (directory / "summary.json").write_text(json.dumps(summary))

            report_path = render_report(directory)

            report = report_path.read_text()
            self.assertIn("Overall state: PASS", report)
            self.assertIn("srt-1080p25-5m", report)
            self.assertIn("throughput_ratio", report)
            self.assertIn("sha256:test", report)


if __name__ == "__main__":
    unittest.main()
