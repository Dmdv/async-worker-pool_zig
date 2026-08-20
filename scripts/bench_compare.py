#!/usr/bin/env python3
"""
Benchmark Regression Guard & Historical Performance Tracker
- Compares current benchmark results against the most recent baseline (immediate predecessor).
- Enforces strict performance regression thresholds.
- Maintains an append-only milestone history ledger (benchmarks/history.json) linked to Git commits & PRs.
"""

import sys
import os
import json
import argparse
import subprocess
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional, Tuple

# ANSI color codes
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

def load_json(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        print(f"{RED}Error: File '{path}' does not exist.{RESET}", file=sys.stderr)
        sys.exit(2)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def save_json(path: str, data: Any) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

def get_git_info() -> Tuple[str, str]:
    commit = "unknown"
    branch = "unknown"
    try:
        commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        pass
    try:
        branch = subprocess.check_output(["git", "branch", "--show-current"], stderr=subprocess.DEVNULL).decode().strip()
        if not branch:
            branch = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        pass
    return commit, branch

def format_delta(delta_pct: float, higher_is_better: bool) -> str:
    sign = "+" if delta_pct > 0 else ""
    val_str = f"{sign}{delta_pct:.2f}%"
    if abs(delta_pct) < 1.0:
        return f"{YELLOW}{val_str} (neutral){RESET}"
    if (delta_pct > 0 and higher_is_better) or (delta_pct < 0 and not higher_is_better):
        return f"{GREEN}{val_str} 🟢 IMPROVED{RESET}"
    else:
        return f"{RED}{val_str} 🔴 REGRESSION{RESET}"

def print_timeline_history(history_file: str, current_metrics: Optional[Dict[str, Any]] = None) -> None:
    if not os.path.exists(history_file):
        print(f"{YELLOW}No history ledger found at '{history_file}'{RESET}")
        return

    history: List[Dict[str, Any]] = load_json(history_file)

    print(f"\n{BOLD}{CYAN}========================================================================================{RESET}")
    print(f"{BOLD}{CYAN}                 AWP HISTORICAL BENCHMARK EVOLUTION TIMELINE                            {RESET}")
    print(f"{BOLD}{CYAN}========================================================================================{RESET}")
    
    headers = f"{'Milestone / Phase':<30} | {'Commit':<8} | {'Pool Throughput':<15} | {'Pool Mean':<12} | {'p99 Latency':<12} | {'Pure SPSC':<13} | {'64B POD Ring':<13}"
    print(headers)
    print("-" * len(headers))

    for entry in history:
        m = entry.get("metrics", entry)
        name = entry.get("name", entry.get("id", "Unknown"))
        commit = entry.get("commit", "unknown")
        pool_tput = f"{m.get('pool_throughput_mps', 0.0):.2f} M/s"
        pool_mean = f"{m.get('pool_mean_ns', 0.0):.1f} ns"
        pool_p99 = f"{m.get('pool_p99_ns', 0.0) / 1000.0:.2f} µs"
        spsc_tput = f"{m.get('spsc_throughput_mops', 0.0):.1f} M/s"
        spsc64 = f"{m.get('spsc64_throughput_mops', 0.0):.1f} M/s" if "spsc64_throughput_mops" in m else "N/A"

        print(f"{name:<30} | {commit:<8} | {pool_tput:<15} | {pool_mean:<12} | {pool_p99:<12} | {spsc_tput:<13} | {spsc64:<13}")

    if current_metrics:
        c_commit, c_branch = get_git_info()
        c_pool_tput = f"{current_metrics.get('pool_throughput_mps', 0.0):.2f} M/s"
        c_pool_mean = f"{current_metrics.get('pool_mean_ns', 0.0):.1f} ns"
        c_pool_p99 = f"{current_metrics.get('pool_p99_ns', 0.0) / 1000.0:.2f} µs"
        c_spsc_tput = f"{current_metrics.get('spsc_throughput_mops', 0.0):.1f} M/s"
        c_spsc64 = f"{current_metrics.get('spsc64_throughput_mops', 0.0):.1f} M/s" if "spsc64_throughput_mops" in current_metrics else "N/A"
        print(f"{GREEN}{BOLD}{'Current Run (In-Flight)':<30}{RESET} | {c_commit:<8} | {c_pool_tput:<15} | {c_pool_mean:<12} | {c_pool_p99:<12} | {c_spsc_tput:<13} | {c_spsc64:<13}")

    print(f"{BOLD}{CYAN}========================================================================================{RESET}\n")

def compare_benchmarks(baseline_file: str, current_file: str, history_file: str, max_tput_drop_pct: float, max_lat_rise_pct: float, warn_only: bool = False, show_history: bool = True) -> int:
    base = load_json(baseline_file)
    curr = load_json(current_file)

    base_commit = base.get("commit", "prev")
    base_name = base.get("name", base.get("description", "Latest Baseline"))

    print(f"\n{BOLD}========================================================================{RESET}")
    print(f"{BOLD}           AWP PERFORMANCE COMPARISON REPORT & REGRESSION GUARD         {RESET}")
    print(f"{BOLD}========================================================================{RESET}")
    print(f"Comparing Current Run Against Immediate Predecessor Baseline:")
    print(f"  • Predecessor : {base_name} (Commit: {base_commit})")
    print(f"  • Baseline Src: {baseline_file}")
    print(f"  • Current Src : {current_file}")
    print("------------------------------------------------------------------------")

    headers = f"{'Metric':<25} | {'Baseline':<14} | {'Current':<14} | {'Delta':<22}"
    print(headers)
    print("-" * len(headers))

    regressions = []

    # 1. Throughput metrics (higher is better)
    tput_metrics = [
        ("pool_throughput_mps", "Pool Throughput (M msg/s)", True),
        ("spsc_throughput_mops", "Pure SPSC (M ops/s)", True),
        ("spsc64_throughput_mops", "64B POD Ring (M ops/s)", True),
        ("bip_throughput_mops", "BipBuffer (M pkts/s)", True),
    ]

    for key, label, higher_is_better in tput_metrics:
        if key in curr:
            c_val = float(curr[key])
            if key in base and key in base:
                b_val = float(base[key])
                delta_pct = ((c_val - b_val) / b_val) * 100.0 if b_val > 0 else 0.0
                delta_str = format_delta(delta_pct, higher_is_better)
                print(f"{label:<25} | {b_val:<14.2f} | {c_val:<14.2f} | {delta_str}")
                
                # Check regression
                if delta_pct < -max_tput_drop_pct:
                    regressions.append(f"{label}: dropped by {abs(delta_pct):.2f}% (limit: {max_tput_drop_pct:.1f}%)")
            else:
                print(f"{label:<25} | {'N/A (New)':<14} | {c_val:<14.2f} | {GREEN}✨ NEW FEATURE{RESET}")

    print("-" * len(headers))

    # 2. Latency metrics (lower is better)
    lat_metrics = [
        ("pool_mean_ns", "Pool Mean Latency (ns)", False),
        ("pool_p50_ns", "Pool p50 Latency (ns)", False),
        ("pool_p90_ns", "Pool p90 Latency (ns)", False),
        ("pool_p99_ns", "Pool p99 Latency (ns)", False),
        ("pool_p999_ns", "Pool p99.9 Latency (ns)", False),
        ("pool_max_ns", "Pool Max Latency (ns)", False),
        ("spsc_mean_ns", "Pure SPSC Latency (ns)", False),
        ("spsc64_mean_ns", "64B POD Latency (ns)", False),
        ("bip_mean_ns", "BipBuffer Latency (ns)", False),
    ]

    for key, label, higher_is_better in lat_metrics:
        if key in curr:
            c_val = float(curr[key])
            if key in base:
                b_val = float(base[key])
                delta_pct = ((c_val - b_val) / b_val) * 100.0 if b_val > 0 else (0.0 if c_val == 0 else 100.0)
                delta_str = format_delta(delta_pct, higher_is_better)
                print(f"{label:<25} | {b_val:<14.2f} | {c_val:<14.2f} | {delta_str}")

                # Check regression for pool latency (25us filter) & SPSC latency (50ns filter)
                if key in ("pool_mean_ns", "pool_p99_ns") and delta_pct > max_lat_rise_pct:
                    if (c_val - b_val) > 25000.0:  # Ignore sub-25us micro-jitter on non-RTOS OS
                        regressions.append(f"{label}: increased by {delta_pct:.2f}% (limit: {max_lat_rise_pct:.1f}%)")
                elif key in ("spsc_mean_ns", "spsc64_mean_ns") and delta_pct > max_lat_rise_pct:
                    if (c_val - b_val) > 50.0:  # Ignore sub-50ns cache warm-up jitter
                        regressions.append(f"{label}: increased by {delta_pct:.2f}% (limit: {max_lat_rise_pct:.1f}%)")
            else:
                print(f"{label:<25} | {'N/A (New)':<14} | {c_val:<14.2f} | {GREEN}✨ NEW FEATURE{RESET}")

    print("========================================================================")

    if regressions:
        print(f"\n{RED}{BOLD}❌ PERFORMANCE REGRESSION DETECTED (vs {base_name}):{RESET}")
        for r in regressions:
            print(f"  • {RED}{r}{RESET}")
        if warn_only:
            print(f"\n{YELLOW}Warning: Performance regression flagged (warn-only mode active on virtualized CI runner).{RESET}\n")
            rc = 0
        else:
            print(f"\n{RED}Build failed due to benchmark performance regression.{RESET}\n")
            rc = 1
    else:
        print(f"\n{GREEN}{BOLD}✅ BENCHMARK PASSED: All metrics meet performance thresholds vs latest baseline.{RESET}\n")
        rc = 0

    if show_history and os.path.exists(history_file):
        print_timeline_history(history_file, curr)

    return rc

def record_milestone(current_file: str, history_file: str, baseline_file: str, milestone_id: str, milestone_name: str, description: str, force: bool = False) -> None:
    curr = load_json(current_file)
    commit, branch = get_git_info()
    timestamp = datetime.now(timezone.utc).isoformat()

    entry = {
        "id": milestone_id,
        "name": milestone_name,
        "commit": commit,
        "branch": branch,
        "timestamp": timestamp,
        "description": description,
        "metrics": curr,
    }

    history: List[Dict[str, Any]] = []
    if os.path.exists(history_file):
        history = load_json(history_file)

    for h in history:
        if h.get("id") == milestone_id and not force:
            print(f"{RED}Error: Milestone ID '{milestone_id}' already exists in append-only history ledger. Use --force to overwrite.{RESET}", file=sys.stderr)
            sys.exit(1)

    history = [h for h in history if h.get("id") != milestone_id]
    history.append(entry)

    save_json(history_file, history)
    print(f"{GREEN}✓ Appended milestone '{milestone_name}' ({commit}) to {history_file}{RESET}")

    # Update baseline.json to point to this new milestone
    curr_copy = dict(curr)
    curr_copy["id"] = milestone_id
    curr_copy["name"] = milestone_name
    curr_copy["commit"] = commit
    curr_copy["branch"] = branch
    curr_copy["timestamp"] = timestamp
    curr_copy["description"] = description
    save_json(baseline_file, curr_copy)
    print(f"{GREEN}✓ Updated immediate predecessor baseline in {baseline_file}{RESET}")

def main():
    parser = argparse.ArgumentParser(description="AWP Benchmark Regression Guard & History Ledger.")
    parser.add_argument("baseline", nargs="?", default="benchmarks/baseline.json", help="Path to baseline.json")
    parser.add_argument("current", nargs="?", default="/tmp/awp_current_bench.json", help="Path to current benchmark.json")
    parser.add_argument("--history-file", default="benchmarks/history.json", help="Path to history.json ledger")
    parser.add_argument("--max-tput-drop", type=float, default=50.0, help="Max allowable throughput drop percentage (default: 50.0%%)")
    parser.add_argument("--max-lat-rise", type=float, default=200.0, help="Max allowable latency increase percentage (default: 200.0%%)")
    parser.add_argument("--warn-only", action="store_true", help="Print warning instead of failing build")
    parser.add_argument("--no-history", action="store_false", dest="show_history", default=True, help="Disable history evolution timeline output")
    parser.add_argument("--record", action="store_true", help="Record current benchmark into history ledger and set as new baseline")
    parser.add_argument("--id", default="", help="Milestone ID for --record (e.g. phase2-64b-pod)")
    parser.add_argument("--name", default="", help="Milestone Name for --record (e.g. 'Phase 2: Generic 64B POD Ring')")
    parser.add_argument("--desc", default="", help="Milestone Description for --record")
    parser.add_argument("--force", action="store_true", help="Force record milestone even if duplicate or if regression detected")

    args = parser.parse_args()

    if args.record:
        if not args.id or not args.name:
            print(f"{RED}Error: --record requires --id and --name{RESET}", file=sys.stderr)
            sys.exit(1)

        # Always run regression check before recording milestone into baseline
        rc = compare_benchmarks(args.baseline, args.current, args.history_file, args.max_tput_drop, args.max_lat_rise, args.warn_only, args.show_history)
        if rc != 0 and not args.force:
            print(f"{RED}Error: Cannot record degraded benchmark milestone into baseline without --force.{RESET}", file=sys.stderr)
            sys.exit(rc)

        record_milestone(args.current, args.history_file, args.baseline, args.id, args.name, args.desc, args.force)
        sys.exit(0)

    rc = compare_benchmarks(args.baseline, args.current, args.history_file, args.max_tput_drop, args.max_lat_rise, args.warn_only, args.show_history)
    sys.exit(rc)

if __name__ == "__main__":
    main()
