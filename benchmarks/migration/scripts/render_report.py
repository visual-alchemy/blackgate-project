#!/usr/bin/env python3
"""Render benchmark JSON evidence as a reviewable Markdown report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _value(value: Any) -> str:
    if isinstance(value, float):
        return f"{value:.6f}"
    return str(value)


def render_report(result_directory: Path) -> Path:
    summary_path = result_directory / "summary.json"
    if not summary_path.is_file():
        raise FileNotFoundError(f"missing benchmark summary: {summary_path}")
    summary = json.loads(summary_path.read_text())
    metadata = summary.get("metadata", {})
    status = str(summary.get("status", "unknown")).upper()
    lines = [
        "# Blackgate C versus Rust performance report",
        "",
        f"Overall state: {status}",
        "",
        "## Environment",
        "",
        "| Field | Value |",
        "| --- | --- |",
    ]
    metadata_fields = (
        ("Ubuntu image digest", "ubuntu_image_digest"),
        ("Kernel", "kernel"),
        ("CPU", "cpu"),
        ("Rust", "rust"),
        ("FFmpeg", "ffmpeg"),
        ("Git commit", "git_commit"),
        ("Started", "started_at"),
        ("Finished", "finished_at"),
    )
    for label, key in metadata_fields:
        lines.append(f"| {label} | {metadata.get(key, 'unavailable')} |")

    for comparison in summary.get("comparisons", []):
        decision = comparison["decision"]
        lines.extend(
            [
                "",
                f"## {comparison['workload']}",
                "",
                f"Decision: {str(decision['status']).upper()}",
                "",
                "| Metric | C median | Rust median | Observed | Gate | Pass |",
                "| --- | ---: | ---: | ---: | ---: | :---: |",
            ]
        )
        for metric_name, metric in decision.get("metrics", {}).items():
            observed_key = "ratio" if "ratio" in metric else "delta"
            lines.append(
                "| "
                + " | ".join(
                    [
                        metric_name,
                        _value(metric["c"]),
                        _value(metric["rust"]),
                        _value(metric[observed_key]),
                        f"{metric['operator']} {_value(metric['threshold'])}",
                        "yes" if metric["pass"] else "no",
                    ]
                )
                + " |"
            )
        reasons = decision.get("reasons", [])
        if reasons:
            lines.extend(["", "Reasons:", ""])
            lines.extend(f"- {reason}" for reason in reasons)

    report_path = result_directory / "REPORT.md"
    report_path.write_text("\n".join(lines) + "\n")
    return report_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_directory", type=Path)
    args = parser.parse_args()
    try:
        path = render_report(args.result_directory)
    except (OSError, KeyError, TypeError, ValueError) as error:
        parser.error(str(error))
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
