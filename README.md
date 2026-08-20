# async-worker-pool_zig

High-throughput, ultra-low-latency sharded worker pool and lock-free ring engine implemented in **Zig 0.16**.

Engineered for High-Frequency Trading (HFT), real-time market data streaming, and deterministic nanosecond-scale message dispatch. Parallel project to the C11 core [`async-worker-pool`](https://github.com/Dmdv/async-worker-pool).

---

## Table of Contents

- [Key Architectural Features](#key-architectural-features)
- [Cross-Language Benchmark Comparison](#cross-language-benchmark-comparison-1000000-messages)
- [Building and Running Benchmarks](#building-and-running-benchmarks)
- [License](#license)

---

## Key Architectural Features

- **Multi-Tiered Memory Architecture:** `std.heap.ArenaAllocator` for $O(1)$ pool lifecycle teardown + pre-allocated embedded ring slabs for zero-allocation hot paths. See [`docs/ALLOCATORS_REVIEW.md`](docs/ALLOCATORS_REVIEW.md).
- **Phase 1 Hardware Hardening & HugePages:** 2MB HugePages (`MAP_HUGETLB`), Transparent HugePages (`MADV_HUGEPAGE`), startup prefaulting (0 Minor Page Faults), and verified `mlock`. See [`docs/PHASE1_HARDWARE_SPECIFICATION.md`](docs/PHASE1_HARDWARE_SPECIFICATION.md).
- **Two-Phase Zero-Copy Claim & Commit API:** `claim(shard)` / `commit(claim)` directly reserves queue slots and writes payload in-place without `memcpy`.
- **Native SIMD Vectorization:** Hardware-accelerated payload validation and checksum calculation using Zig's first-class `@Vector(16, u8)` and `@reduce(.Add, ...)` primitives (auto-vectorized to ARM NEON / AVX-512).
- **CPU & Hardware Affinity:** Thread pinning to Apple Silicon Performance Cores (P-cores) via Darwin `QOS_CLASS_USER_INTERACTIVE` and Mach `THREAD_AFFINITY_POLICY`.
- **Compile-Time Specialization:** Zero-cost queue sizing, power-of-two mask generation, and memory layouts parameterized via Zig `comptime`.
- **Hardware-Calibrated Timestamps:** Monotonic POSIX `clock_gettime(CLOCK_MONOTONIC)` timing eliminating frequency scaling traps across Apple Silicon, ARM64, and x86_64. Detailed in [`docs/PHASE1_HARDWARE_SPECIFICATION.md`](docs/PHASE1_HARDWARE_SPECIFICATION.md).

---

## Cross-Language Benchmark Comparison (1,000,000 Messages)

Executed on Apple Silicon Performance Cores (Darwin arm64):

| Engine / Project | Language | Workload | Throughput | Median (p50) | p99 Latency | Mean Latency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (4 Pinned Workers) | **6.10 M msg/sec** 🚀 | **< 100 ns** | **3.00 µs** (3,000 ns) | **804.4 ns** (0.80 µs) |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Pointer SPSC Ring (0 CAS) | **152.95 M ops/sec** 🚀 | **< 7 ns** | **< 10 ns** | **6.54 ns** |
| **`awp-zig-rs`** ([`bindings/rust`](bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **5.45 M msg/sec** 🚀 | **< 150 ns** | **3.80 µs** (3,800 ns) | **920.0 ns** (0.92 µs) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3.46 µs** (3,458 ns) | **1.11 ms** (1,110,000 ns) | **2.11 µs** (2,109 ns) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Raw SPSC Ring | **62.50 M ops/sec** | **< 16 ns** | **< 20 ns** | **16.00 ns** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3.35 µs** (3,350 ns) | **1.15 ms** (1,150,000 ns) | **1.87 µs** (1,870 ns) |

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine (Phase 1)** | **C11 Engine** (`async-worker-pool`) | Delta / Notes |
| :--- | :--- | :--- | :--- |
| **Min (Observed Floor)** | **15 ns** (0.015 µs) | **83 ns** (0.083 µs) | Observed Single-Hop Floor |
| **p50 (Median)** | **< 100 ns** | **3.46 µs** (3,458 ns) | **Zig is > 30x lower latency** 🚀 |
| **p90** | **1.00 µs** (1,000 ns) | **11.17 µs** (11,167 ns) | **Zig is 11.2x lower latency** 🚀 |
| **p99 (Tail)** | **3.00 µs** (3,000 ns) | **1.11 ms** (1,110,000 ns) | **Zig is 370x lower tail jitter** 🚀 |
| **p99.9** | **154.0 µs** (154,000 ns) | **1.27 ms** (1,270,000 ns) | **Zig is 8.2x lower tail jitter** 🚀 |
| **Max** | **201.0 µs** (201,000 ns) | **1.67 ms** (1,670,000 ns) | **Zig is 8.3x lower peak jitter** 🚀 |
| **Pure SPSC Throughput** | **152.95 Million ops/sec** | **62.50 Million ops/sec** | **Zig is 2.45x faster (6.54 ns/op)** 🚀 |

<p align="center">
  <img src="docs/images/benchmark_throughput.png" width="48%" alt="Throughput Comparison" />
  <img src="docs/images/benchmark_spsc_comparison.png" width="48%" alt="SPSC Comparison" />
</p>
<p align="center">
  <img src="docs/images/benchmark_tail_latencies.png" width="96%" alt="Tail Latencies Distribution" />
</p>

Full benchmark reports and documentation:
- [`docs/EVOLUTION_PLAN.md`](docs/EVOLUTION_PLAN.md) — Complete microarchitectural theory, optimizations & roadmap
- [`docs/HOT_PATH_OPTIMIZATIONS.md`](docs/HOT_PATH_OPTIMIZATIONS.md) — Deep technical breakdown of all 6 hot-path optimizations
- [`docs/MEMORY_MODELS.md`](docs/MEMORY_MODELS.md) — Comprehensive low-latency memory models & cache architecture
- [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md) — Benchmark reports & latency histograms
- [`docs/ALLOCATORS_REVIEW.md`](docs/ALLOCATORS_REVIEW.md) — Detailed Zig 0.16 allocator analysis

---

## Building and Running Benchmarks

### Prerequisites
- Zig `0.16.0` or later.

### Run Benchmark Suite
```bash
# Run release-optimized multi-threaded dispatch benchmark
zig build bench -Doptimize=ReleaseFast
```

---

## License

MIT License.
