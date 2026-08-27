#!/usr/bin/env python3
"""Statistical decision model for C-versus-Rust migration benchmarks."""

from __future__ import annotations

import math
import statistics
from typing import Any


METRIC_NAMES = (
    "throughput_mbps",
    "packet_loss",
    "cpu_percent",
    "peak_rss_bytes",
    "latency_ms",
    "startup_ms",
    "failover_gap_ms",
)

RATIO_RULES = (
    ("throughput_ratio", "throughput_mbps", "throughput_ratio_min", "min"),
    ("cpu_ratio", "cpu_percent", "cpu_ratio_max", "max"),
    ("peak_rss_ratio", "peak_rss_bytes", "peak_rss_ratio_max", "max"),
    ("latency_ratio", "latency_ms", "latency_ratio_max", "max"),
    ("startup_ratio", "startup_ms", "startup_ratio_max", "max"),
    (
        "failover_gap_ratio",
        "failover_gap_ms",
        "failover_gap_ratio_max",
        "max",
    ),
)


def _number(run: dict[str, Any], name: str) -> float:
    value = run.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"metric {name} must be numeric")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f"metric {name} must be finite")
    return value


def median_metrics(runs: list[dict]) -> dict:
    """Return one median for every required benchmark metric."""
    if not runs:
        raise ValueError("at least one benchmark run is required")
    return {
        name: float(statistics.median(_number(run, name) for run in runs))
        for name in METRIC_NAMES
    }


def coefficient_of_variation(values: list[float]) -> float:
    """Return population standard deviation divided by absolute mean."""
    if len(values) < 2:
        return 0.0
    numeric = [float(value) for value in values]
    mean = statistics.fmean(numeric)
    if mean == 0.0:
        return 0.0 if all(value == 0.0 for value in numeric) else math.inf
    return statistics.pstdev(numeric) / abs(mean)


def _ratio(numerator: float, denominator: float) -> float:
    if denominator == 0.0:
        return 1.0 if numerator == 0.0 else math.inf
    return numerator / denominator


def _ratio_result(
    c_value: float,
    rust_value: float,
    threshold: float,
    direction: str,
) -> dict:
    ratio = _ratio(rust_value, c_value)
    passed = ratio >= threshold if direction == "min" else ratio <= threshold
    return {
        "c": c_value,
        "rust": rust_value,
        "ratio": ratio,
        "threshold": threshold,
        "operator": ">=" if direction == "min" else "<=",
        "pass": passed,
    }


def compare(c_runs: list[dict], rust_runs: list[dict], thresholds: dict) -> dict:
    """Compare repeated C and Rust runs against approved migration limits."""
    reasons: list[str] = []
    if not c_runs or not rust_runs:
        return {
            "status": "inconclusive",
            "metrics": {},
            "reasons": ["C and Rust each require at least one benchmark run"],
        }

    try:
        c_median = median_metrics(c_runs)
        rust_median = median_metrics(rust_runs)
    except (TypeError, ValueError) as error:
        return {
            "status": "inconclusive",
            "metrics": {},
            "reasons": [str(error)],
        }

    variation_limit = float(thresholds["coefficient_of_variation_max"])
    unstable = False
    for engine_name, runs in (("C", c_runs), ("Rust", rust_runs)):
        for metric_name in METRIC_NAMES:
            variation = coefficient_of_variation(
                [_number(run, metric_name) for run in runs]
            )
            if variation > variation_limit:
                unstable = True
                reasons.append(
                    f"{engine_name} {metric_name} coefficient of variation "
                    f"{variation:.6f} exceeds {variation_limit:.6f}"
                )

    metrics: dict[str, dict] = {}
    for decision_name, metric_name, threshold_name, direction in RATIO_RULES:
        metrics[decision_name] = _ratio_result(
            c_median[metric_name],
            rust_median[metric_name],
            float(thresholds[threshold_name]),
            direction,
        )

    loss_delta = rust_median["packet_loss"] - c_median["packet_loss"]
    loss_threshold = float(thresholds["packet_loss_delta_max"])
    metrics["packet_loss_delta"] = {
        "c": c_median["packet_loss"],
        "rust": rust_median["packet_loss"],
        "delta": loss_delta,
        "threshold": loss_threshold,
        "operator": "<=",
        "pass": loss_delta <= loss_threshold,
    }

    failed_names = [name for name, result in metrics.items() if not result["pass"]]
    for name in failed_names:
        result = metrics[name]
        observed = result.get("ratio", result.get("delta"))
        reasons.append(
            f"{name} {observed:.6f} violates "
            f"{result['operator']} {result['threshold']:.6f}"
        )

    if unstable:
        status = "inconclusive"
    elif failed_names:
        status = "fail"
    else:
        status = "pass"

    return {"status": status, "metrics": metrics, "reasons": reasons}
