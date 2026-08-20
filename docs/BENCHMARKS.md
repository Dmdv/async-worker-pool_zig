# Performance Benchmarks & C Comparison (Zig 0.16)

High-performance benchmarks for `async-worker-pool_zig` comparing native Zig 0.16 implementation against the C11 engine ([`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)) and Rust bindings (`awp-rs`).

---

## Table of Contents

- [1. Comparative Results Table (1,000,000 Messages)](#1-comparative-results-table-1000000-messages)
- [2. Hardware Hardening & Architecture Specification](PHASE1_HARDWARE_SPECIFICATION.md)
- [3. Memory & Allocator Strategy](#2-memory--allocator-strategy)
- [4. Running the Benchmark](#3-running-the-benchmark)

---

## 1. Comparative Results Table (1,000,000 Messages)

| Engine | Language | Workload | Throughput | Median (p50) | p99 Latency | Mean Latency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (4 Pinned Workers) | **5.38 M msg/sec** 🚀 | **< 100 ns** | **1.00 µs** (1,000 ns) | **547.0 ns** (0.55 µs) |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Pointer SPSC Ring (0 CAS) | **171.76 M ops/sec** 🚀 | **< 6 ns** | **< 8 ns** | **5.82 ns** |
| **`async-worker-pool_zig`** (Phase 2) | Zig 0.16 | 64-Byte POD Cacheline Ring (`BookUpdate64`) | **28.54 M ops/sec** 🚀 | **< 30 ns** | **< 45 ns** | **35.03 ns** |
| **`awp-zig-rs`** ([`bindings/rust`](../bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **5.45 M msg/sec** 🚀 | **< 150 ns** | **3.80 µs** (3,800 ns) | **920.0 ns** (0.92 µs) |
| **`async-worker-pool`** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3.46 µs** (3,458 ns) | **1.11 ms** (1,110,000 ns) | **2.11 µs** (2,109 ns) |
| **`async-worker-pool`** | C11 | Raw SPSC Ring | **62.50 M ops/sec** | **< 16 ns** | **< 20 ns** | **16.00 ns** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3.35 µs** (3,350 ns) | **1.15 ms** (1,150,000 ns) | **1.87 µs** (1,870 ns) |

---

### Historical Benchmark Evolution Ledger

Tracked strictly against Git milestone commits in [`benchmarks/history.json`](../benchmarks/history.json):

| Milestone / Phase | Git Commit | Pool Throughput | Pool Mean Latency | p99 Tail Latency | Pure SPSC Ring | 64B POD Ring |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Phase 0: Initial Zig Port** | `e228513` | 5.33 M msg/s | 2,330.7 ns | 102.00 µs | 98.1 M ops/s (10.2 ns) | N/A |
| **Phase 1: Hardware Hardening & HugePages** | `249e3f2` | 5.38 M msg/s | 547.0 ns | 1.00 µs | 171.8 M ops/s (5.82 ns) | N/A |
| **Phase 2: Generic 64B POD SPSC Ring** | *Current* | **5.62 M msg/s** | **405.9 ns** | **1.00 µs** | **161.4 M ops/s (6.20 ns)** | **28.54 M ops/s (35.0 ns)** |

---

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine (Phase 1 Final)** | **C11 Engine** (`async-worker-pool`) | Delta / Notes |
| :--- | :--- | :--- | :--- |
| **Min (Observed Floor)** | **15 ns** (0.015 µs) | **120 ns** (0.120 µs) | Observed Single-Hop Floor |
| **p50 (Median)** | **< 100 ns** | **3.46 µs** (3,458 ns) | **Zig is > 34x lower latency** 🚀 |
| **p90** | **1.00 µs** (1,000 ns) | **11.17 µs** (11,167 ns) | **Zig is 11.2x lower latency** 🚀 |
| **p99 (Tail)** | **1.00 µs** (1,000 ns) | **1.11 ms** (1,110,000 ns) | **Zig is 1,110x lower tail jitter** 🚀 |
| **p99.9** | **96.0 µs** (96,000 ns) | **1.27 ms** (1,270,000 ns) | **Zig is 13.2x lower tail jitter** 🚀 |
| **Max** | **128.0 µs** (128,000 ns) | **1.67 ms** (1,670,000 ns) | **Zig is 13.0x lower peak jitter** 🚀 |
| **Pure SPSC Throughput** | **171.76 Million ops/sec** | **62.50 Million ops/sec** | **Zig is 2.75x faster (5.82 ns/op)** 🚀 |

<p align="center">
  <img src="images/benchmark_throughput.png" width="48%" alt="Throughput Comparison" />
  <img src="images/benchmark_spsc_comparison.png" width="48%" alt="SPSC Comparison" />
</p>
<p align="center">
  <img src="images/benchmark_tail_latencies.png" width="96%" alt="Tail Latencies Distribution" />
</p>

---

## 2. Memory & Allocator Strategy

See [`ALLOCATORS_REVIEW.md`](ALLOCATORS_REVIEW.md) for full architectural details.

1. **`std.heap.ArenaAllocator`**:
   Used for `AwpPool.init()` and `AwpPool.deinit()`. All worker handles, ring structures, and synchronization primitives are allocated from the arena. On pool teardown, all resources are reclaimed in $O(1)$ time with zero leaks.
2. **Embedded Ring Slabs**:
   Each ring buffer cell holds a pre-allocated `Frame`. Enqueue operations reserve slots via atomic sequence numbers with zero runtime memory allocation.
3. **SIMD Autovectorization**:
   Uses `@Vector(16, u8)` and `@reduce(.Add, ...)` to vectorize 64-byte payload checksums into native ARM NEON instructions.

---

## 3. Running the Benchmark

```bash
zig build bench -Doptimize=ReleaseFast
```
