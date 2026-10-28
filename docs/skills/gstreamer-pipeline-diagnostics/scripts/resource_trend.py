#!/usr/bin/env python3
"""Long-run resource trend for a running Blackgate release: one CSV line every N seconds.

Answers the only question a short benchmark cannot: does anything grow over hours? It reads
/proc directly (RSS, CPU time, thread count, open file descriptors, process count), so it never
touches the stats socket, never spawns an Erlang process and adds no measurable load.

    # start (detached so an SSH disconnect does not kill it)
    setsid nohup python3 docs/skills/gstreamer-pipeline-diagnostics/scripts/resource_trend.py \
        --interval 30 --out ~/blackgate-trend >/dev/null 2>&1 &

    # next morning: is the line flat or rising?
    python3 docs/skills/gstreamer-pipeline-diagnostics/scripts/resource_trend.py \
        --summarize ~/blackgate-trend/<file>.csv

Columns: ts, node_rss_mb, node_cpu_pct, node_threads, node_fds, node_procs,
         engines, engines_rss_mb, engines_cpu_pct, engines_fds, load1, uptime_s
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import statistics
import sys
import time

ENGINE_MARKER = "priv/native/build/blackgate-engine"
# A release node is found by the directory its boot script was started from, and the two layouts
# differ: a development tree boots from `_build/prod/rel/blackgate/...`, while the appliance boots
# from `/opt/blackgate/releases/<version>/...`. Matching only the first silently recorded
# node_rss_mb / node_cpu_pct / node_threads / node_fds as 0 on a real gateway, which reads as a
# broken monitor rather than a missing marker.
NODE_MARKERS = ("rel/blackgate", "/blackgate/releases/")
HEADER = (
    "ts,node_rss_mb,node_cpu_pct,node_threads,node_fds,node_procs,"
    "engines,engines_rss_mb,engines_cpu_pct,engines_fds,load1,uptime_s"
)


def read_cmdline(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            return handle.read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        return ""


def find_processes() -> tuple[list[int], list[tuple[int, str]]]:
    """Return (node pids, [(engine pid, route id)])."""
    nodes: list[int] = []
    engines: list[tuple[int, str]] = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        cmdline = read_cmdline(pid)
        if not cmdline:
            continue
        if ENGINE_MARKER in cmdline:
            parts = cmdline.split()
            route_id = next(
                (p for p in reversed(parts) if len(p) == 36 and p.count("-") == 4), "?"
            )
            engines.append((pid, route_id))
        elif "beam" in cmdline and any(m in cmdline for m in NODE_MARKERS):
            # `bin/blackgate rpc` starts a helper beam from the same release directory with
            # `-boot .../start_clean`, so it would otherwise be counted as a second node and
            # spike node RSS/threads/fds for one sample. Only the daemon counts.
            if "start_clean" in cmdline or "rpc-eval" in cmdline:
                continue
            nodes.append(pid)
    return nodes, engines


def stat_fields(pid: int) -> tuple[float, int, int] | None:
    """(cpu_seconds, threads, open fds) for a pid."""
    try:
        with open(f"/proc/{pid}/stat") as handle:
            raw = handle.read()
        fields = raw[raw.rfind(")") + 2:].split()
        ticks = os.sysconf("SC_CLK_TCK")
        cpu = (int(fields[11]) + int(fields[12])) / ticks
        threads = 0
        with open(f"/proc/{pid}/status") as handle:
            for line in handle:
                if line.startswith("Threads:"):
                    threads = int(line.split()[1])
                    break
        fds = len(os.listdir(f"/proc/{pid}/fd"))
        return cpu, threads, fds
    except (OSError, IndexError, ValueError):
        return None


def rss_mb(pid: int) -> float:
    try:
        with open(f"/proc/{pid}/status") as handle:
            for line in handle:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except OSError:
        pass
    return 0.0


def sample(state: dict) -> list[str]:
    now = time.monotonic()
    node_pids, engines = find_processes()
    engine_pids = [pid for pid, _ in engines]

    def cpu_pct(pids: list[int], prev_map: dict) -> tuple[float, float, dict]:
        total_cpu = 0.0
        total_rss = 0.0
        new_prev = {}
        elapsed = now - state["at"] if state["at"] else 0.0
        for pid in pids:
            result = stat_fields(pid)
            if result is None:
                continue
            cpu, _threads, _fds = result
            total_rss += rss_mb(pid)
            prev = prev_map.get(pid)
            if prev is not None and elapsed > 0:
                total_cpu += max(cpu - prev, 0.0) / elapsed * 100.0
            new_prev[pid] = cpu
        return total_cpu, total_rss, new_prev

    node_cpu, node_rss, node_prev = cpu_pct(node_pids, state["node_cpu"])
    eng_cpu, eng_rss, eng_prev = cpu_pct(engine_pids, state["engine_cpu"])
    state["node_cpu"] = node_prev
    state["engine_cpu"] = eng_prev
    state["at"] = now

    node_threads = sum(
        (stat_fields(pid) or (0, 0, 0))[1] for pid in node_pids
    )
    node_fds = sum((stat_fields(pid) or (0, 0, 0))[2] for pid in node_pids)
    engine_fds = sum((stat_fields(pid) or (0, 0, 0))[2] for pid in engine_pids)
    load1 = os.getloadavg()[0]

    with open("/proc/uptime") as handle:
        uptime_s = int(float(handle.read().split()[0]))

    return [
        dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        f"{node_rss:.1f}",
        f"{node_cpu:.2f}",
        str(node_threads),
        str(node_fds),
        str(len(node_pids)),
        str(len(engine_pids)),
        f"{eng_rss:.1f}",
        f"{eng_cpu:.2f}",
        str(engine_fds),
        f"{load1:.2f}",
        str(uptime_s),
    ]


def run(interval: float, out_path: str) -> None:
    state = {"node_cpu": {}, "engine_cpu": {}, "at": None}
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    fresh = not os.path.exists(out_path) or os.path.getsize(out_path) == 0
    with open(out_path, "a", buffering=1) as handle:
        if fresh:
            handle.write(HEADER + "\n")
        while True:
            try:
                handle.write(",".join(sample(state)) + "\n")
            except Exception as error:  # a monitor must not die on a transient /proc race
                handle.write(f"# sample error: {error}\n")
            time.sleep(interval)


def summarize(path: str) -> int:
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("ts,"):
                continue
            parts = line.split(",")
            if len(parts) != 12:
                continue
            try:
                rows.append({"ts": parts[0], **{
                    k: float(v) for k, v in zip(
                        ["node_rss_mb", "node_cpu_pct", "node_threads", "node_fds", "node_procs",
                         "engines", "engines_rss_mb", "engines_cpu_pct", "engines_fds",
                         "load1", "uptime_s"], parts[1:])}})
            except ValueError:
                continue
    if len(rows) < 4:
        print(f"only {len(rows)} usable samples in {path}; need at least 4")
        return 1

    span_h = (dt.datetime.fromisoformat(rows[-1]["ts"])
              - dt.datetime.fromisoformat(rows[0]["ts"])).total_seconds() / 3600.0
    print(f"{path}\n{len(rows)} samples over {span_h:.2f} h "
          f"({rows[0]['ts']} -> {rows[-1]['ts']})\n")
    print(f"{'column':16} {'first':>10} {'median':>10} {'last':>10} {'min':>10} {'max':>10} "
          f"{'drift/h':>10}  verdict")
    alarm = []
    window = max(1, len(rows) // 5)
    for column in ("node_rss_mb", "node_cpu_pct", "node_fds", "node_threads", "node_procs",
                   "engines", "engines_rss_mb", "engines_cpu_pct", "engines_fds", "load1"):
        values = [r[column] for r in rows]
        head, tail = statistics.median(values[:window]), statistics.median(values[-window:])
        drift = (tail - head) / span_h if span_h > 0 else 0.0
        rel = (tail - head) / head * 100.0 if head else 0.0
        verdict = "flat"
        if column in ("node_rss_mb", "engines_rss_mb", "node_fds", "engines_fds", "node_threads") \
                and rel > 10.0 and drift > 0:
            verdict = "RISING"
            alarm.append(f"{column}: {rel:.1f}% higher at the end ({drift:+.2f} per hour)")
        print(f"{column:16} {values[0]:10.2f} {statistics.median(values):10.2f} {values[-1]:10.2f} "
              f"{min(values):10.2f} {max(values):10.2f} {drift:10.2f}  {verdict}")
    print()
    if alarm:
        print("VERDICT: something grows — investigate before shipping:")
        for item in alarm:
            print("  -", item)
        return 1
    print("VERDICT: no growth signal — RSS, fd and thread counts end where they started.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interval", type=float, default=30.0, help="seconds between samples")
    parser.add_argument("--out", default=os.path.expanduser("~/blackgate-trend"),
                        help="CSV path, or a directory to create a timestamped file in")
    parser.add_argument("--summarize", metavar="CSV", help="read an existing CSV and report drift")
    args = parser.parse_args()

    if args.summarize:
        return summarize(args.summarize)

    out = args.out
    if not out.endswith(".csv"):
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        out = os.path.join(out, f"blackgate-trend-{stamp}.csv")
    run(args.interval, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
