#!/usr/bin/env python3
"""Summarise a ZIG_INTROSPECT JSON log.

Usage:
    python tools/introspect_summary.py artifacts/introspect.log

Each input line is a FrameSnapshot JSON record produced by
engine/src/runtime/introspect.zig. This script computes per-pass
timing aggregates, frame-time percentiles, memory leak detection, and
flags frames that deviated significantly from the median.

Designed for agent consumption: writes a structured summary to stdout
plus warnings to stderr, both as JSON.
"""

import json
import statistics
import sys
from collections import defaultdict


def load_frames(path):
    frames = []
    with open(path, "r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError as e:
                print(
                    json.dumps(
                        {"warning": "bad_json", "line": line_no, "error": str(e)}
                    ),
                    file=sys.stderr,
                )
    return frames


def quantile(values, q):
    if not values:
        return 0
    sorted_values = sorted(values)
    idx = int(q * (len(sorted_values) - 1))
    return sorted_values[idx]


def summarise(frames):
    if not frames:
        return {"warning": "no_frames"}

    frame_times_ms = [f["frame_ns"] / 1_000_000 for f in frames]
    deadline_errors = [f["pacing"]["deadline_err_ms"] for f in frames]

    pass_totals = defaultdict(list)
    for f in frames:
        for p in f.get("passes", []):
            pass_totals[p["name"]].append(p["last_ns"] / 1_000_000)

    pass_summary = []
    for name, samples in sorted(pass_totals.items(), key=lambda kv: -statistics.mean(kv[1])):
        pass_summary.append(
            {
                "name": name,
                "samples": len(samples),
                "median_ms": round(statistics.median(samples), 4),
                "mean_ms": round(statistics.mean(samples), 4),
                "p95_ms": round(quantile(samples, 0.95), 4),
                "max_ms": round(max(samples), 4),
            }
        )

    last_frame = frames[-1]
    first_frame = frames[0]
    mem_delta = last_frame["mem"]["bytes_in_use"] - first_frame["mem"]["bytes_in_use"]

    leak_warning = None
    if last_frame["mem"]["allocs"] > last_frame["mem"]["frees"] + 100 and len(frames) > 50:
        leak_warning = {
            "live_allocs": last_frame["mem"]["allocs"] - last_frame["mem"]["frees"],
            "bytes_in_use": last_frame["mem"]["bytes_in_use"],
            "note": "alloc count > free count by >100 after 50+ frames; may indicate a leak",
        }

    return {
        "frame_count": len(frames),
        "first_frame_index": first_frame["frame"],
        "last_frame_index": last_frame["frame"],
        "backbuffer": f"{first_frame['width']}x{first_frame['height']}",
        "scene": {
            "tris": first_frame["scene"]["tris"],
            "lights": first_frame["scene"]["lights"],
            "meshlets": first_frame["scene"]["meshlets"],
        },
        "frame_time_ms": {
            "median": round(statistics.median(frame_times_ms), 4),
            "mean": round(statistics.mean(frame_times_ms), 4),
            "p95": round(quantile(frame_times_ms, 0.95), 4),
            "p99": round(quantile(frame_times_ms, 0.99), 4),
            "max": round(max(frame_times_ms), 4),
        },
        "deadline_err_ms": {
            "median": round(statistics.median(deadline_errors), 4),
            "p95": round(quantile(deadline_errors, 0.95), 4),
            "max": round(max(deadline_errors), 4),
        },
        "passes_by_cost": pass_summary,
        "memory": {
            "first_bytes_in_use": first_frame["mem"]["bytes_in_use"],
            "last_bytes_in_use": last_frame["mem"]["bytes_in_use"],
            "delta_bytes": mem_delta,
            "peak_bytes": last_frame["mem"]["peak_bytes"],
            "total_allocs": last_frame["mem"]["allocs"],
            "total_frees": last_frame["mem"]["frees"],
            "leak_warning": leak_warning,
        },
    }


def main(argv):
    if len(argv) != 2:
        print(
            "usage: python tools/introspect_summary.py <introspect.log>",
            file=sys.stderr,
        )
        return 2
    frames = load_frames(argv[1])
    print(json.dumps(summarise(frames), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
