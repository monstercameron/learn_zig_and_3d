"""Analyze frame_times.csv exported by the engine's frame pacing tracker.

Usage:
    python tools/analyze-frame-times.py [path/to/frame_times.csv]

Prints variance metrics and optionally saves a comparison baseline.
"""

import sys
import csv
import math
import os

DEFAULT_PATH = "artifacts/perf/frame_times.csv"


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({k: float(v) for k, v in row.items() if k != "frame"})
    return rows


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    idx = (len(sorted_vals) - 1) * p / 100.0
    lo = int(math.floor(idx))
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def analyze(rows, label="total_ms"):
    vals = [r[label] for r in rows]
    if not vals:
        print("No data.")
        return {}

    n = len(vals)
    mean = sum(vals) / n
    variance = sum((v - mean) ** 2 for v in vals) / n
    stddev = math.sqrt(variance)
    sorted_vals = sorted(vals)
    p50 = percentile(sorted_vals, 50)
    p95 = percentile(sorted_vals, 95)
    p99 = percentile(sorted_vals, 99)
    mn = sorted_vals[0]
    mx = sorted_vals[-1]
    jitter = max(abs(mx - mean), abs(mean - mn))

    # Frame-to-frame delta stats
    deltas = [abs(vals[i] - vals[i - 1]) for i in range(1, n)]
    delta_mean = sum(deltas) / len(deltas) if deltas else 0
    delta_max = max(deltas) if deltas else 0
    sorted_deltas = sorted(deltas)
    delta_p95 = percentile(sorted_deltas, 95)

    return {
        "count": n,
        "mean": mean,
        "stddev": stddev,
        "variance": variance,
        "min": mn,
        "max": mx,
        "p50": p50,
        "p95": p95,
        "p99": p99,
        "jitter": jitter,
        "delta_mean": delta_mean,
        "delta_p95": delta_p95,
        "delta_max": delta_max,
    }


def print_report(stats, label):
    print(f"\n{'='*60}")
    print(f"  Frame Pacing Analysis: {label}")
    print(f"{'='*60}")
    print(f"  Samples:        {stats['count']}")
    print(f"  Mean:           {stats['mean']:.3f} ms")
    print(f"  Std Dev:        {stats['stddev']:.3f} ms")
    print(f"  Variance:       {stats['variance']:.4f} ms²")
    print(f"  Min:            {stats['min']:.3f} ms")
    print(f"  Max:            {stats['max']:.3f} ms")
    print(f"  p50:            {stats['p50']:.3f} ms")
    print(f"  p95:            {stats['p95']:.3f} ms")
    print(f"  p99:            {stats['p99']:.3f} ms")
    print(f"  Jitter (peak):  {stats['jitter']:.3f} ms")
    print(f"  Frame-to-frame delta mean: {stats['delta_mean']:.3f} ms")
    print(f"  Frame-to-frame delta p95:  {stats['delta_p95']:.3f} ms")
    print(f"  Frame-to-frame delta max:  {stats['delta_max']:.3f} ms")
    print(f"{'='*60}\n")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH

    if not os.path.exists(path):
        print(f"File not found: {path}")
        sys.exit(1)

    rows = load_csv(path)

    # Skip first 5 frames (warmup)
    if len(rows) > 10:
        rows = rows[5:]

    for label in ["total_ms", "cpu_ms", "deadline_error_ms"]:
        stats = analyze(rows, label)
        if stats:
            print_report(stats, label)


if __name__ == "__main__":
    main()
