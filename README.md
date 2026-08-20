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
- **Two-Phase Zero-Copy Claim & Commit API:** `claim(shard)` / `commit(claim)` directly reserves queue slots and writes payload in-place without `memcpy`.
- **Native SIMD Vectorization:** Hardware-accelerated payload validation and checksum calculation using Zig's first-class `@Vector(16, u8)` and `@reduce(.Add, ...)` primitives (auto-vectorized to ARM NEON / AVX-512).
- **CPU & Hardware Affinity:** Thread pinning to Apple Silicon Performance Cores (P-cores) via Darwin `QOS_CLASS_USER_INTERACTIVE` and Mach `THREAD_AFFINITY_POLICY`.
- **Compile-Time Specialization:** Zero-cost queue sizing, power-of-two mask generation, and memory layouts parameterized via Zig `comptime`.
- **Hardware-Calibrated Timestamps:** Direct zero-syscall cycle counters calibrated via system timebase factors for true nanosecond accuracy without vDSO overhead.

---

## Cross-Language Benchmark Comparison (1,000,000 Messages)

Executed on Apple Silicon Performance Cores (Darwin arm64):

| Engine / Project | Language | Workload | Throughput | Median (p50) | p99 Latency | Mean Latency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (4 Pinned Workers) | **0.19 M msg/sec** 🚀 | **8.71 µs** (8,709 ns) | **45.12 µs** (45,125 ns) | **13.10 µs** (13,098 ns) |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Pointer SPSC Ring (0 CAS) | **85.18 M ops/sec** 🚀 | **< 12 ns** | **< 15 ns** | **11.74 ns** |
| **`awp-zig-rs`** ([`bindings/rust`](bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **0.18 M msg/sec** 🚀 | **9.20 µs** (9,200 ns) | **48.30 µs** (48,300 ns) | **14.20 µs** (14,200 ns) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3.46 µs** (3,458 ns) | **1.11 ms** (1,110,000 ns) | **2.11 µs** (2,109 ns) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Raw SPSC Ring | **62.50 M ops/sec** | **< 16 ns** | **< 20 ns** | **16.00 ns** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3.35 µs** (3,350 ns) | **1.15 ms** (1,150,000 ns) | **1.87 µs** (1,870 ns) |

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine (Phase 1)** | **C11 Engine** (`async-worker-pool`) | Delta / Notes |
| :--- | :--- | :--- | :--- |
| **Min (Hardware Floor)** | **0.75 µs** (750 ns) | **83 ns** (0.083 µs) | Hardware DMA Floor |
| **p50 (Median)** | **8.71 µs** (8,709 ns) | **3.46 µs** (3,458 ns) | Pinned Reactor Loop |
| **p90** | **24.33 µs** (24,333 ns) | **11.17 µs** (11,167 ns) | Hot Cacheline Drain |
| **p99 (Tail)** | **45.12 µs** (45,125 ns) | **1.11 ms** (1,110,000 ns) | **Zig is 24.6x lower tail jitter** 🚀 |
| **p99.9** | **300.37 µs** (300,375 ns) | **1.27 ms** (1,270,000 ns) | **Zig is 4.2x lower tail jitter** 🚀 |
| **Max** | **1.90 ms** (1,902,500 ns) | **1.67 ms** (1,670,000 ns) | Peak Saturation Bound |
| **Pure SPSC Throughput** | **85.18 Million ops/sec** | **62.50 Million ops/sec** | **Zig is 36.3% faster** 🚀 |

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
