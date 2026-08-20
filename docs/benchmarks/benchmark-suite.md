# HFT Benchmark Methodology & Regression Guard

Reliable benchmarking in Low-Latency HFT systems requires strict microarchitectural calibration, core isolation, and automated regression guards.

---

## 🔬 Benchmarking Methodology

All benchmarks in AWP adhere to the following principles:

1. **Hardware Pinning:** Threads are strictly pinned to dedicated Apple Silicon Performance Cores (P-cores) or Linux isolated cores (`isolcpus`).
2. **Warmup Cycles:** 10,000 unmeasured iterations to ensure L1/L2 instruction and data cache warmup.
3. **Monotonic Timing:** High-resolution nanosecond timestamps via POSIX `clock_gettime(CLOCK_MONOTONIC)` to eliminate frequency scaling distortion.
4. **Latency Percentiles:** Complete histogram computation across 1,000,000 samples measuring **Min**, **p50 (Median)**, **p90**, **p99 (Tail)**, **p99.9**, **p99.99**, and **Max**.

---

## 📊 Comprehensive Performance Results

```
=========================================================================================================================================
                 AWP HISTORICAL BENCHMARK EVOLUTION TIMELINE                            
=========================================================================================================================================
Milestone / Phase              | Commit   | Pool Throughput | Pool Mean    | p99 Latency  | Pure SPSC     | 64B POD Ring  | BipRing      
-----------------------------------------------------------------------------------------------------------------------------------------
Phase 0: Initial Zig Port      | e228513  | 5.33 M/s        | 2330.7 ns    | 102.00 µs    | 98.1 M/s      | N/A           | N/A          
Phase 1: Hardware Hardening    | 249e3f2  | 5.38 M/s        | 547.0 ns     | 1.00 µs      | 171.8 M/s     | N/A           | N/A          
Phase 2: Generic 64B POD Ring  | 14f7510  | 6.43 M/s        | 629.8 ns     | 4.00 µs      | 94.4 M/s      | 21.7 M/s      | N/A          
Phase 3: Variable-Length BipRing | 1c23c78  | 6.03 M/s      | 506.0 ns     | 1.00 µs      | 176.4 M/s     | 19.4 M/s      | 9.4 M/s      
=========================================================================================================================================
```

---

## 🛡️ Automated Regression Guard (`scripts/bench_compare.py`)

AWP integrates an automated CI benchmark regression guard:
- **Baseline Tracking:** Compares current build metrics against `benchmarks/baseline.json`.
- **Append-Only History:** Records milestone commits into `benchmarks/history.json`.
- **Threshold Enforcement:** Fails CI if throughput drops by > 50% or tail latency increases by > 200%.

```bash
# Run comparison against latest baseline
python3 scripts/bench_compare.py benchmarks/baseline.json /tmp/awp_current_bench.json
```
