#!/usr/bin/env python3
"""Measure game present cadence over explicitly selected scene-frame intervals."""
import argparse
import csv
import math
from pathlib import Path
from statistics import mean, median, quantiles


def measure(path, first, last):
    frame_times = {}
    with path.open(newline="") as f:
        for row in csv.reader(f, delimiter="\t"):
            if len(row) != 3 or row[1] != "@frame_ms":
                continue
            frame, value = int(row[0]), float(row[2])
            if first <= frame <= last and math.isfinite(value) and value > 0:
                frame_times[frame] = value
    if len(frame_times) < 300:
        raise SystemExit(f"{path}: {len(frame_times)} valid samples; select at least 300.")
    values = list(frame_times.values())
    p95 = quantiles(values, n=20, method="inclusive")[18]
    print(f"{path.parent.name}: {len(values)} frames, {1000 / mean(values):.1f} game presents/s, "
          f"p50 {median(values):.2f} ms, p95 {p95:.2f} ms")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs=6, metavar="TSV FIRST LAST")
    args = parser.parse_args()
    for i in (0, 3):
        path, first, last = args.runs[i:i+3]
        measure(Path(path), int(first), int(last))


if __name__ == "__main__":
    main()
