#!/usr/bin/env python3
"""Run reproducible C-versus-Rust Blackgate migration benchmarks."""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from statistics import median
from typing import Any, Callable

from result_model import METRIC_NAMES, compare
from render_report import render_report


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SOCKET = Path("/tmp/hydra_unix_sock")
THRESHOLDS = ROOT / "benchmarks" / "migration" / "thresholds.json"
WORKLOAD_DIR = ROOT / "benchmarks" / "migration" / "workloads"


class RunnerError(RuntimeError):
    """Raised when benchmark lifecycle or evidence collection fails."""


class OutputPump:
    def __init__(self, stream) -> None:
        self.stream = stream
        self.parts: list[bytes] = []
        self.thread = threading.Thread(target=self._read, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _read(self) -> None:
        try:
            while True:
                chunk = os.read(self.stream.fileno(), 4096)
                if not chunk:
                    return
                self.parts.append(chunk)
        finally:
            self.stream.close()

    def bytes(self) -> bytes:
        return b"".join(self.parts)

    def text(self) -> str:
        return self.bytes().decode("utf-8", errors="replace")

    def join(self) -> None:
        self.thread.join(timeout=2.0)


class SocketCollector:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.server: socket.socket | None = None
        self.connection: socket.socket | None = None
        self.parts: list[bytes] = []
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        if self.path.exists() or self.path.is_symlink():
            if not stat.S_ISSOCK(self.path.lstat().st_mode):
                raise RunnerError(f"refusing to replace non-socket path: {self.path}")
            self.path.unlink()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.server.listen(1)
        self.server.settimeout(0.1)
        self.thread = threading.Thread(target=self._collect, daemon=True)
        self.thread.start()

    def _collect(self) -> None:
        assert self.server is not None
        while not self.stop_event.is_set() and self.connection is None:
            try:
                self.connection, _ = self.server.accept()
                self.connection.settimeout(0.1)
            except TimeoutError:
                continue
            except OSError:
                return
        while not self.stop_event.is_set() and self.connection is not None:
            try:
                chunk = self.connection.recv(65536)
                if not chunk:
                    return
                self.parts.append(chunk)
            except TimeoutError:
                continue
            except OSError:
                return

    def text(self) -> str:
        return b"".join(self.parts).decode("utf-8", errors="replace")

    def close(self) -> None:
        self.stop_event.set()
        for stream in (self.connection, self.server):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        if self.thread is not None:
            self.thread.join(timeout=1.0)
        if self.path.exists() or self.path.is_symlink():
            if stat.S_ISSOCK(self.path.lstat().st_mode):
                self.path.unlink()


def reserve_ports(count: int) -> list[int]:
    reservations: list[socket.socket] = []
    try:
        for _ in range(count):
            reservation = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            reservation.bind(("127.0.0.1", 0))
            reservations.append(reservation)
        return [reservation.getsockname()[1] for reservation in reservations]
    finally:
        for reservation in reservations:
            reservation.close()


def _srt_uri(port: int, mode: str) -> str:
    return f"srt://127.0.0.1:{port}?mode={mode}&latency=120"


def build_init(workload: dict, ports: list[int]) -> dict:
    required = 1 + int("secondary_source" in workload) + len(workload["destinations"])
    if len(ports) < required:
        raise RunnerError(f"workload requires {required} reserved ports")

    cursor = 0
    source_port = ports[cursor]
    cursor += 1
    source = workload["source"]
    if source["protocol"] == "srt":
        primary = {"type": "srtsrc", "uri": _srt_uri(source_port, source["mode"])}
    else:
        primary = {"type": "udpsrc", "uri": f"udp://127.0.0.1:{source_port}"}

    init: dict[str, Any] = {
        "type": "init",
        "route_id": f"bench-{workload['id']}",
        "primary_source": primary,
        "auto_join": True,
        "sinks": [],
    }
    if "secondary_source" in workload:
        secondary_port = ports[cursor]
        cursor += 1
        secondary = workload["secondary_source"]
        init["secondary_source"] = {
            "type": "srtsrc",
            "uri": _srt_uri(secondary_port, secondary["mode"]),
        }

    for destination in workload["destinations"]:
        port = ports[cursor]
        cursor += 1
        if destination["protocol"] == "srt":
            init["sinks"].append(
                {"type": "srtsink", "uri": _srt_uri(port, destination["mode"])}
            )
        else:
            init["sinks"].append(
                {"type": "udpsink", "address": "127.0.0.1", "port": port}
            )
    return init


def _ffmpeg_sender(workload: dict, port: int, duration_seconds: float) -> list[str]:
    video = workload["video"]
    rate = f"{video['fps_num']}/{video['fps_den']}"
    if workload["source"]["protocol"] == "srt":
        output = _srt_uri(port, "caller")
    else:
        output = f"udp://127.0.0.1:{port}?pkt_size=1316"
    return [
        shutil.which("ffmpeg") or "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
        f"testsrc2=size={video['width']}x{video['height']}:rate={rate}",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=1000:sample_rate=48000",
        "-t",
        f"{duration_seconds:.3f}",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-b:v",
        f"{video['bitrate_mbps']}M",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-f",
        "mpegts",
        output,
    ]


def _ffmpeg_receiver(destination: dict, port: int) -> tuple[str, list[str]]:
    if destination["protocol"] == "srt":
        receiver_mode = "listener" if destination["mode"] == "caller" else "caller"
        source = _srt_uri(port, receiver_mode)
        phase = "pre" if receiver_mode == "listener" else "post"
    else:
        source = f"udp://127.0.0.1:{port}?fifo_size=1000000&overrun_nonfatal=1"
        phase = "pre"
    return (
        phase,
        [
            shutil.which("ffmpeg") or "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            source,
            "-map",
            "0",
            "-c",
            "copy",
            "-f",
            "null",
            "-",
        ],
    )


def build_plan(
    engine: Path,
    workload: dict,
    ports: list[int],
    duration_seconds: float | None = None,
) -> dict:
    timing = workload["timing"]
    duration = duration_seconds or (
        timing["warmup_seconds"] + timing["measurement_seconds"]
    )
    init = build_init(workload, ports)
    cursor = 1 + int("secondary_source" in workload)
    receivers: list[list[str]] = []
    phases: list[str] = []
    for destination in workload["destinations"]:
        phase, command = _ffmpeg_receiver(destination, ports[cursor])
        receivers.append(command)
        phases.append(phase)
        cursor += 1

    senders = [_ffmpeg_sender(workload, ports[0], duration + 3.0)]
    if "secondary_source" in workload:
        senders.append(_ffmpeg_sender(workload, ports[1], duration + 3.0))

    return {
        "route_id": init["route_id"],
        "engine": [str(engine), init["route_id"]],
        "init": init,
        "receivers": receivers,
        "receiver_phases": phases,
        "sender": senders[0],
        "senders": senders,
        "ports": ports,
    }


def _terminate_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        process.terminate()
    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            process.kill()
        process.wait(timeout=2.0)


def _start_auxiliary(command: list[str]) -> tuple[subprocess.Popen[bytes], OutputPump]:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    assert process.stderr is not None
    pump = OutputPump(process.stderr)
    pump.start()
    return process, pump


def _process_sample(pid: int) -> tuple[float | None, int | None]:
    proc_stat = Path(f"/proc/{pid}/stat")
    proc_status = Path(f"/proc/{pid}/status")
    if proc_stat.exists() and proc_status.exists():
        raw = proc_stat.read_text()
        fields = raw[raw.rfind(")") + 2 :].split()
        ticks = os.sysconf("SC_CLK_TCK")
        cpu_seconds = (int(fields[11]) + int(fields[12])) / ticks
        rss_match = re.search(r"^VmRSS:\s+(\d+)\s+kB$", proc_status.read_text(), re.M)
        rss_bytes = int(rss_match.group(1)) * 1024 if rss_match else 0
        return cpu_seconds, rss_bytes
    try:
        raw = subprocess.check_output(
            ["ps", "-o", "time=,rss=", "-p", str(pid)],
            text=True,
        ).strip()
        time_text, rss_text = raw.split()
        pieces = [float(piece) for piece in time_text.split(":")]
        cpu_seconds = pieces[-1] + 60 * pieces[-2]
        if len(pieces) == 3:
            cpu_seconds += 3600 * pieces[0]
        return cpu_seconds, int(rss_text) * 1024
    except (OSError, subprocess.SubprocessError, ValueError):
        return None, None


def _wait_for(
    condition: Callable[[], bool],
    process: subprocess.Popen[bytes],
    timeout_seconds: float,
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        if process.poll() is not None:
            return False
        time.sleep(0.02)
    return condition()


def _socket_stats(frames: str, route_id: str) -> list[dict]:
    normalized = frames.replace(f"route_id:{route_id}", "", 1)
    stats: list[dict] = []
    for line in normalized.splitlines():
        candidate = line.removeprefix("stats_sink:").strip()
        if not candidate.startswith("{"):
            continue
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            stats.append(value)
    return stats


def _metric_values(stats: list[dict], *names: str) -> list[float]:
    values: list[float] = []
    for item in stats:
        for name in names:
            value = item.get(name)
            if isinstance(value, (int, float)) and math.isfinite(float(value)):
                values.append(float(value))
                break
    return values


def _throughput_values(stats: list[dict]) -> list[float]:
    source_rates = [
        float(item["receive-rate-mbps"])
        for item in stats
        if "source" in item
        and isinstance(item.get("receive-rate-mbps"), (int, float))
        and math.isfinite(float(item["receive-rate-mbps"]))
        and float(item["receive-rate-mbps"]) > 0.0
    ]
    if source_rates:
        return source_rates
    return [
        float(item["send-rate-mbps"])
        for item in stats
        if "sink-index" in item
        and isinstance(item.get("send-rate-mbps"), (int, float))
        and math.isfinite(float(item["send-rate-mbps"]))
        and float(item["send-rate-mbps"]) > 0.0
    ]


def _metrics_from_evidence(
    stats: list[dict],
    cpu_start: float | None,
    cpu_end: float | None,
    elapsed: float,
    peak_rss: int,
    startup_ms: float,
    failover_gaps: list[float],
) -> dict:
    throughput = _throughput_values(stats)
    losses = _metric_values(stats, "packets-received-lost", "packets-sent-lost")
    latencies = _metric_values(stats, "rtt-ms")
    cpu_percent = 0.0
    if cpu_start is not None and cpu_end is not None and elapsed > 0:
        cpu_percent = max(0.0, (cpu_end - cpu_start) / elapsed * 100.0)
    return {
        "throughput_mbps": float(median(throughput)) if throughput else 0.0,
        "packet_loss": max(losses, default=0.0),
        "cpu_percent": cpu_percent,
        "peak_rss_bytes": float(peak_rss),
        "latency_ms": float(median(latencies)) if latencies else 0.0,
        "startup_ms": startup_ms,
        "failover_gap_ms": max(failover_gaps, default=0.0),
    }


def run_engine_lifecycle(
    engine_name: str,
    engine: Path,
    workload: dict,
    socket_path: Path,
    duration_seconds: float,
    *,
    plan: dict | None = None,
    warmup_seconds: float = 0.0,
    measurement_seconds: float | None = None,
) -> dict:
    if not engine.is_file() or not os.access(engine, os.X_OK):
        raise RunnerError(f"engine is missing or not executable: {engine}")
    ports = reserve_ports(1 + int("secondary_source" in workload) + len(workload["destinations"]))
    active_plan = plan or build_plan(engine, workload, ports, duration_seconds)
    collector = SocketCollector(socket_path)
    process: subprocess.Popen[bytes] | None = None
    auxiliary: list[tuple[subprocess.Popen[bytes], OutputPump, str]] = []
    stdout_pump: OutputPump | None = None
    stderr_pump: OutputPump | None = None
    forced_stop = False

    try:
        for phase, command in zip(
            active_plan["receiver_phases"], active_plan["receivers"], strict=True
        ):
            if phase == "pre":
                child, pump = _start_auxiliary(command)
                auxiliary.append((child, pump, "receiver"))
        collector.start()
        env = os.environ.copy()
        env["BLACKGATE_BENCH_SOCKET"] = str(socket_path)
        start_time = time.monotonic()
        process = subprocess.Popen(
            [str(engine.resolve()), active_plan["route_id"]],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        assert process.stdin is not None
        assert process.stdout is not None
        assert process.stderr is not None
        stdout_pump = OutputPump(process.stdout)
        stderr_pump = OutputPump(process.stderr)
        stdout_pump.start()
        stderr_pump.start()
        process.stdin.write(
            (json.dumps(active_plan["init"], separators=(",", ":")) + "\n").encode()
        )
        process.stdin.flush()

        time.sleep(0.25)
        for phase, command in zip(
            active_plan["receiver_phases"], active_plan["receivers"], strict=True
        ):
            if phase == "post":
                child, pump = _start_auxiliary(command)
                auxiliary.append((child, pump, "receiver"))
        for command in active_plan["senders"]:
            child, pump = _start_auxiliary(command)
            auxiliary.append((child, pump, "sender"))

        if not _wait_for(
            lambda: " to PLAYING" in stdout_pump.text()
            or " to PAUSED" in stdout_pump.text(),
            process,
            20.0,
        ):
            raise RunnerError(
                "engine failed before PLAYING/PAUSED\n"
                f"stdout:\n{stdout_pump.text()}\nstderr:\n{stderr_pump.text()}"
            )
        startup_ms = (time.monotonic() - start_time) * 1000.0
        handshake = f"route_id:{active_plan['route_id']}"
        if not _wait_for(lambda: handshake in collector.text(), process, 2.0):
            raise RunnerError(f"missing IPC handshake: {handshake}")

        cpu_start, initial_rss = _process_sample(process.pid)
        peak_rss = initial_rss or 0
        run_start = time.monotonic()
        measurement = measurement_seconds or max(duration_seconds - warmup_seconds, 0.001)
        original_measurement = max(float(workload["timing"]["measurement_seconds"]), 0.001)
        events = list(workload.get("events", []))
        sent_events: set[int] = set()
        event_sent_at: dict[int, float] = {}
        failover_gaps: list[float] = []

        while time.monotonic() - run_start < duration_seconds:
            if process.poll() is not None:
                raise RunnerError(
                    f"engine exited early ({process.returncode})\n"
                    f"stdout:\n{stdout_pump.text()}\nstderr:\n{stderr_pump.text()}"
                )
            elapsed = time.monotonic() - run_start
            measured_elapsed = max(0.0, elapsed - warmup_seconds)
            for index, event in enumerate(events):
                scaled_at = float(event["at_second"]) * measurement / original_measurement
                if index not in sent_events and measured_elapsed >= scaled_at:
                    command = {key: value for key, value in event.items() if key != "at_second"}
                    process.stdin.write((json.dumps(command) + "\n").encode())
                    process.stdin.flush()
                    sent_events.add(index)
                    event_sent_at[index] = time.monotonic()
            stdout_text = stdout_pump.text()
            for index, event in enumerate(events):
                marker = f"SOURCE_SWITCHED:{event.get('target', '')}"
                if index in event_sent_at and marker in stdout_text:
                    failover_gaps.append((time.monotonic() - event_sent_at.pop(index)) * 1000.0)
            _, rss = _process_sample(process.pid)
            if rss is not None:
                peak_rss = max(peak_rss, rss)
            for child, pump, role in auxiliary:
                if child.poll() is not None and child.returncode not in (0, None):
                    raise RunnerError(
                        f"{role} exited early ({child.returncode})\n{pump.text()}"
                    )
            time.sleep(0.05)

        cpu_end, final_rss = _process_sample(process.pid)
        if final_rss is not None:
            peak_rss = max(peak_rss, final_rss)
        process.stdin.write(b'{"command":"stop-route"}\n')
        process.stdin.flush()
        if not _wait_for(lambda: process.poll() is not None, process, 2.0):
            forced_stop = True
            _terminate_group(process)
        return_code = process.wait(timeout=2.0)
        if engine_name != "c" and (forced_stop or return_code != 0):
            raise RunnerError(
                f"Rust engine shutdown failed ({return_code})\n"
                f"stdout:\n{stdout_pump.text()}\nstderr:\n{stderr_pump.text()}"
            )

        stdout_pump.join()
        stderr_pump.join()
        frames = collector.text()
        stats = _socket_stats(frames, active_plan["route_id"])
        elapsed = max(time.monotonic() - run_start, 0.001)
        metrics = _metrics_from_evidence(
            stats,
            cpu_start,
            cpu_end,
            elapsed,
            peak_rss,
            startup_ms,
            failover_gaps,
        )
        return {
            "engine": engine_name,
            "status": "completed",
            "route_id": active_plan["route_id"],
            "metrics": metrics,
            "forced_stop": forced_stop,
            "return_code": return_code,
            "socket_frames": frames,
            "stdout": stdout_pump.text(),
            "stderr": stderr_pump.text(),
        }
    except (OSError, subprocess.SubprocessError) as error:
        raise RunnerError(str(error)) from error
    finally:
        for child, pump, _role in auxiliary:
            _terminate_group(child)
            pump.join()
        if process is not None and process.poll() is None:
            _terminate_group(process)
        if process is not None and process.stdin is not None:
            process.stdin.close()
        if stdout_pump is not None:
            stdout_pump.join()
        if stderr_pump is not None:
            stderr_pump.join()
        collector.close()


def _timing(
    workload: dict,
    quick: bool,
    repetitions_override: int | None = None,
) -> tuple[float, float, int]:
    if quick:
        return 0.5, 3.0, 1
    timing = workload["timing"]
    return (
        float(timing["warmup_seconds"]),
        float(timing["measurement_seconds"]),
        repetitions_override
        if repetitions_override is not None
        else int(timing["repetitions"]),
    )


def _run_workload(
    c_engine: Path,
    rust_engine: Path,
    workload: dict,
    output: Path,
    quick: bool,
    repetitions_override: int | None,
) -> dict:
    warmup, measurement, repetitions = _timing(workload, quick, repetitions_override)
    workload_output = output / workload["id"]
    workload_output.mkdir(parents=True, exist_ok=True)
    runs: dict[str, list[dict]] = {"c": [], "rust": []}
    for engine_name, engine in (("c", c_engine), ("rust", rust_engine)):
        for repetition in range(1, repetitions + 1):
            ports = reserve_ports(
                1 + int("secondary_source" in workload) + len(workload["destinations"])
            )
            plan = build_plan(engine, workload, ports, warmup + measurement)
            result = run_engine_lifecycle(
                engine_name,
                engine,
                workload,
                DEFAULT_SOCKET,
                warmup + measurement,
                plan=plan,
                warmup_seconds=warmup,
                measurement_seconds=measurement,
            )
            evidence_path = workload_output / f"{engine_name}-run-{repetition}.json"
            evidence_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            runs[engine_name].append(result["metrics"])

    thresholds = json.loads(THRESHOLDS.read_text())
    decision = compare(runs["c"], runs["rust"], thresholds)
    comparison = {
        "workload": workload["id"],
        "quick": quick,
        "repetitions": repetitions,
        "c_runs": runs["c"],
        "rust_runs": runs["rust"],
        "decision": decision,
    }
    (workload_output / "comparison.json").write_text(
        json.dumps(comparison, indent=2, sort_keys=True) + "\n"
    )
    return comparison


def _metadata(started_at: str, finished_at: str) -> dict:
    def command_output(command: list[str]) -> str:
        try:
            return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
        except (OSError, subprocess.SubprocessError):
            return "unavailable"

    return {
        "started_at": started_at,
        "finished_at": finished_at,
        "git_commit": os.environ.get("BLACKGATE_BENCH_GIT_COMMIT")
        or command_output(["git", "rev-parse", "HEAD"]),
        "kernel": command_output(["uname", "-a"]),
        "cpu": command_output(["sh", "-c", "lscpu 2>/dev/null | head -20 || sysctl -n machdep.cpu.brand_string"]),
        "rust": os.environ.get("BLACKGATE_BENCH_RUST_VERSION")
        or command_output(["rustc", "--version"]),
        "ffmpeg": command_output(["ffmpeg", "-version"]).splitlines()[0],
        "ubuntu_image_digest": os.environ.get("BLACKGATE_BENCH_IMAGE_DIGEST", "local"),
    }


def _load_workloads(path: Path | None, all_workloads: bool) -> list[dict]:
    if all_workloads:
        paths = [item for item in sorted(WORKLOAD_DIR.glob("*.json")) if item.stem != "non-sdi-soak"]
    elif path is not None:
        paths = [path]
    else:
        raise RunnerError("provide --workload or --all")
    return [json.loads(item.read_text()) for item in paths]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    def positive_int(value: str) -> int:
        parsed = int(value)
        if parsed < 1:
            raise argparse.ArgumentTypeError("must be at least 1")
        return parsed

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--c-engine", required=True, type=Path)
    parser.add_argument("--rust-engine", required=True, type=Path)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--workload", type=Path)
    choice.add_argument("--all", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--quick", action="store_true")
    parser.add_argument(
        "--repetitions",
        type=positive_int,
        help="override workload repetitions for a statistically stable rerun",
    )
    args = parser.parse_args(argv)
    if args.quick and args.repetitions is not None:
        parser.error("--quick cannot be combined with --repetitions")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        workloads = _load_workloads(args.workload, args.all)
        if args.dry_run:
            plans = []
            for workload in workloads:
                port_count = 1 + int("secondary_source" in workload) + len(workload["destinations"])
                ports = list(range(20000, 20000 + port_count))
                plans.append(
                    {
                        "workload": workload["id"],
                        "c": build_plan(args.c_engine, workload, ports),
                        "rust": build_plan(args.rust_engine, workload, ports),
                    }
                )
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "dry-run-plan.json").write_text(
                json.dumps(plans, indent=2, sort_keys=True) + "\n"
            )
            print(json.dumps(plans, indent=2, sort_keys=True))
            return 0

        started_at = datetime.now(timezone.utc).isoformat()
        if args.all:
            run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            output = args.output / run_id
        else:
            output = args.output
        output.mkdir(parents=True, exist_ok=True)
        comparisons = [
            _run_workload(
                args.c_engine,
                args.rust_engine,
                workload,
                output,
                args.quick,
                args.repetitions,
            )
            for workload in workloads
        ]
        finished_at = datetime.now(timezone.utc).isoformat()
        summary = {
            "metadata": _metadata(started_at, finished_at),
            "comparisons": comparisons,
            "status": (
                "pass"
                if all(item["decision"]["status"] == "pass" for item in comparisons)
                else "fail"
            ),
        }
        (output / "summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n"
        )
        render_report(output)
        return 0 if summary["status"] == "pass" else 1
    except (OSError, ValueError, KeyError, RunnerError) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
