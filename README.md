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
- **Phase 2 Generic 64-Byte POD Cacheline SPSC Ring:** `comptime SpscRing(T, capacity)` specialized for 64-byte market data structures (`BookUpdate64`, `Trade64`), slashing memory bandwidth by **98.5%** (64 MB/s vs 4.26 GB/s) and achieving **28.54 M ops/sec** at **35.03 ns** hop latency.
- **Phase 3 Variable-Length Zero-Copy Bipartite Ring (`BipRing` & `BipBuffer`):** Lock-free bipartite circular memory arena coupled with a 16-byte `PacketDescriptor` SPSC ring. Streams arbitrary packet sizes (64B to 1500B MTU) with 0 memory fragmentation and 0 boundary-split copies, delivering **14.21 M pkts/sec** at **70.38 ns** latency.
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
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (4 Pinned Workers) | **5.38 M msg/sec** 🚀 | **< 100 ns** | **1.00 µs** (1,000 ns) | **547.0 ns** (0.55 µs) |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Pointer SPSC Ring (0 CAS) | **171.76 M ops/sec** 🚀 | **< 6 ns** | **< 8 ns** | **5.82 ns** |
| **`async-worker-pool_zig`** (Phase 2) | Zig 0.16 | 64-Byte POD Cacheline Ring (`BookUpdate64`) | **28.54 M ops/sec** 🚀 | **< 30 ns** | **< 45 ns** | **35.03 ns** |
| **`async-worker-pool_zig`** (Phase 3) | Zig 0.16 | Variable-Length Zero-Copy BipRing (64B–1400B) | **14.21 M pkts/sec** 🚀 | **< 50 ns** | **< 80 ns** | **70.38 ns** |
| **`awp-zig-rs`** ([`bindings/rust`](bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **5.45 M msg/sec** 🚀 | **< 150 ns** | **3.80 µs** (3,800 ns) | **920.0 ns** (0.92 µs) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3.46 µs** (3,458 ns) | **1.11 ms** (1,110,000 ns) | **2.11 µs** (2,109 ns) |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Raw SPSC Ring | **62.50 M ops/sec** | **< 16 ns** | **< 20 ns** | **16.00 ns** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3.35 µs** (3,350 ns) | **1.15 ms** (1,150,000 ns) | **1.87 µs** (1,870 ns) |

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine (Phase 1 Final)** | **C11 Engine** (`async-worker-pool`) | Delta / Notes |
| :--- | :--- | :--- | :--- |
| **Min (Observed Floor)** | **15 ns** (0.015 µs) | **83 ns** (0.083 µs) | Observed Single-Hop Floor |
| **p50 (Median)** | **< 100 ns** | **3.46 µs** (3,458 ns) | **Zig is > 34x lower latency** 🚀 |
| **p90** | **1.00 µs** (1,000 ns) | **11.17 µs** (11,167 ns) | **Zig is 11.2x lower latency** 🚀 |
| **p99 (Tail)** | **1.00 µs** (1,000 ns) | **1.11 ms** (1,110,000 ns) | **Zig is 1,110x lower tail jitter** 🚀 |
| **p99.9** | **96.0 µs** (96,000 ns) | **1.27 ms** (1,270,000 ns) | **Zig is 13.2x lower tail jitter** 🚀 |
| **Max** | **128.0 µs** (128,000 ns) | **1.67 ms** (1,670,000 ns) | **Zig is 13.0x lower peak jitter** 🚀 |
| **Pure SPSC Throughput** | **171.76 Million ops/sec** | **62.50 Million ops/sec** | **Zig is 2.75x faster (5.82 ns/op)** 🚀 |

<p align="center">
  <img src="docs/images/benchmark_throughput.png" width="48%" alt="Throughput Comparison" />
  <img src="docs/images/benchmark_spsc_comparison.png" width="48%" alt="SPSC Comparison" />
</p>
<p align="center">
  <img src="docs/images/benchmark_tail_latencies.png" width="96%" alt="Tail Latencies Distribution" />
</p>

Full benchmark reports and documentation:
- [`CHANGELOG.md`](CHANGELOG.md) — Complete release notes, architectural milestones & hardware benchmark history
- [`docs/HFT_EVOLUTION_ROADMAP.md`](docs/HFT_EVOLUTION_ROADMAP.md) — 5-Phase HFT evolution roadmap & implementation status
- [`docs/PHASE1_HARDWARE_SPECIFICATION.md`](docs/PHASE1_HARDWARE_SPECIFICATION.md) — Phase 1 Hardware Hardening & Zero-TLB Memory Subsystem Specification
- [`docs/EVOLUTION_PLAN.md`](docs/EVOLUTION_PLAN.md) — Microarchitectural theory & memory layout models
- [`docs/HOT_PATH_OPTIMIZATIONS.md`](docs/HOT_PATH_OPTIMIZATIONS.md) — Technical breakdown of hot-path optimizations
- [`docs/MEMORY_MODELS.md`](docs/MEMORY_MODELS.md) — Low-latency memory models & cache architecture
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
