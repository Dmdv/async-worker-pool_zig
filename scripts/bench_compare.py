#!/usr/bin/env python3
"""
Benchmark Regression Guard & Performance Comparator
Compares current benchmark results against baseline.json.
Enforces performance regression thresholds.
"""

import sys
import os
import json
import argparse
from typing import Dict, Any, Tuple

# ANSI color codes
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
BOLD = "\033[1m"
RESET = "\033[0m"

def load_json(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        print(f"{RED}Error: File '{path}' does not exist.{RESET}", file=sys.stderr)
        sys.exit(2)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def format_delta(delta_pct: float, higher_is_better: bool) -> str:
    sign = "+" if delta_pct > 0 else ""
    val_str = f"{sign}{delta_pct:.2f}%"
    if abs(delta_pct) < 1.0:
        return f"{YELLOW}{val_str} (neutral){RESET}"
    if (delta_pct > 0 and higher_is_better) or (delta_pct < 0 and not higher_is_better):
        return f"{GREEN}{val_str} 🟢 IMPROVED{RESET}"
    else:
        return f"{RED}{val_str} 🔴 REGRESSION{RESET}"

def compare_benchmarks(baseline_file: str, current_file: str, max_tput_drop_pct: float, max_lat_rise_pct: float) -> int:
    base = load_json(baseline_file)
    curr = load_json(current_file)

    print(f"\n{BOLD}========================================================================{RESET}")
    print(f"{BOLD}           AWP PERFORMANCE COMPARISON REPORT & REGRESSION GUARD         {RESET}")
    print(f"{BOLD}========================================================================{RESET}")
    print(f"Baseline: {baseline_file} ({base.get('engine', 'unknown')})")
    print(f"Current:  {current_file} ({curr.get('engine', 'unknown')})")
    print("------------------------------------------------------------------------")

    headers = f"{'Metric':<25} | {'Baseline':<14} | {'Current':<14} | {'Delta':<22}"
    print(headers)
    print("-" * len(headers))

    regressions = []

    # 1. Throughput metrics (higher is better)
    tput_metrics = [
        ("pool_throughput_mps", "Pool Throughput (M msg/s)", True),
        ("spsc_throughput_mops", "SPSC Ring (M ops/s)", True),
    ]

    for key, label, higher_is_better in tput_metrics:
        if key in base and key in curr:
            b_val = float(base[key])
            c_val = float(curr[key])
            delta_pct = ((c_val - b_val) / b_val) * 100.0 if b_val > 0 else 0.0
            delta_str = format_delta(delta_pct, higher_is_better)
            print(f"{label:<25} | {b_val:<14.2f} | {c_val:<14.2f} | {delta_str}")
            
            # Check regression
            if delta_pct < -max_tput_drop_pct:
                regressions.append(f"{label}: dropped by {abs(delta_pct):.2f}% (limit: {max_tput_drop_pct:.1f}%)")

    print("-" * len(headers))

    # 2. Latency metrics (lower is better)
    lat_metrics = [
        ("pool_mean_ns", "Pool Mean Latency (ns)", False),
        ("pool_p50_ns", "Pool p50 Latency (ns)", False),
        ("pool_p90_ns", "Pool p90 Latency (ns)", False),
        ("pool_p99_ns", "Pool p99 Latency (ns)", False),
        ("pool_p999_ns", "Pool p99.9 Latency (ns)", False),
        ("pool_max_ns", "Pool Max Latency (ns)", False),
        ("spsc_mean_ns", "SPSC Mean Latency (ns)", False),
    ]

    for key, label, higher_is_better in lat_metrics:
        if key in base and key in curr:
            b_val = float(base[key])
            c_val = float(curr[key])
            delta_pct = ((c_val - b_val) / b_val) * 100.0 if b_val > 0 else 0.0
            delta_str = format_delta(delta_pct, higher_is_better)
            print(f"{label:<25} | {b_val:<14.2f} | {c_val:<14.2f} | {delta_str}")

            # Check regression for p99 / mean
            if key in ("pool_mean_ns", "pool_p99_ns") and delta_pct > max_lat_rise_pct:
                regressions.append(f"{label}: increased by {delta_pct:.2f}% (limit: {max_lat_rise_pct:.1f}%)")

    print("========================================================================")

    if regressions:
        print(f"\n{RED}{BOLD}❌ PERFORMANCE REGRESSION DETECTED:{RESET}")
        for r in regressions:
            print(f"  • {RED}{r}{RESET}")
        print(f"\n{RED}Build failed due to benchmark performance regression.{RESET}\n")
        return 1
    else:
        print(f"\n{GREEN}{BOLD}✅ BENCHMARK PASSED: All metrics meet performance thresholds.{RESET}\n")
        return 0

def main():
    parser = argparse.ArgumentParser(description="Compare AWP benchmark JSON results against baseline.")
    parser.add_argument("baseline", help="Path to baseline.json")
    parser.add_argument("current", help="Path to current benchmark.json")
    parser.add_argument("--max-tput-drop", type=float, default=15.0, help="Max allowable throughput drop percentage (default: 15.0%%)")
    parser.add_argument("--max-lat-rise", type=float, default=25.0, help="Max allowable latency increase percentage (default: 25.0%%)")

    args = parser.parse_args()
    rc = compare_benchmarks(args.baseline, args.current, args.max_tput_drop, args.max_lat_rise)
    sys.exit(rc)

if __name__ == "__main__":
    main()
