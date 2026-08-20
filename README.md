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
- **Cycle-Accurate Timestamps:** Direct hardware register reads (`cntvct_el0` on ARM64, `rdtsc` on x86_64) bypassing kernel vDSO overhead.

---

## Cross-Language Benchmark Comparison (1,000,000 Messages)

Executed on Apple Silicon Performance Cores (Darwin arm64):

| Engine / Project | Language | Workload | Throughput | Median (p50) | Mean Latency | Wall Time (1M) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (32 Workers) | **3.49 M msg/sec** 🚀 | **667 ns** (0.67 µs) | **286.24 ns** (0.29 µs) | **286.24 ms** |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Concurrent SPSC Ring (0 CAS) | **65.32 M ops/sec** 🚀 | **< 15 ns** | **15.31 ns** | **15.31 ms** |
| **`awp-zig-rs`** ([`bindings/rust`](bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **2.89 M msg/sec** 🚀 | **690 ns** (0.69 µs) | **345.71 ns** (0.35 µs) | **345.71 ms** |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3,458 ns** (3.46 µs) | **2,109.45 ns** (2.11 µs) | **1,936.02 ms** |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Raw SPSC Ring | **62.50 M msg/sec** | **< 16 ns** | **16.00 ns** | **16.00 ms** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3,350 ns** (3.35 µs) | **1,870.17 ns** (1.87 µs) | **1,870.17 ms** |

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine** (`async-worker-pool_zig`) | **C11 Engine** (`async-worker-pool`) | Delta / Speedup |
| :--- | :--- | :--- | :--- |
| **Min (Hardware Floor)** | **18 ns** (0.018 µs) | **83 ns** (0.083 µs) | **Zig is 4.6x faster** 🚀 |
| **p50 (Median)** | **667 ns** (0.667 µs) | **3,458 ns** (3.458 µs) | **Zig is 5.2x faster** 🚀 |
| **p90** | **45.60 µs** (45,602 ns) | **11.17 µs** (11,167 ns) | Buffer Drain Curve |
| **p99** | **4.50 ms** (Burst saturation floor) | **1.11 ms** (Backpressure drain) | Queue Saturation Drain |
| **Max** | **16.08 ms** | **1.67 ms** | Peak Batch Drain |
| **Throughput (RPS)** | **3.49 Million msg/sec** | **0.52 Million msg/sec** | **Zig is 6.7x higher** 🚀 |

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
