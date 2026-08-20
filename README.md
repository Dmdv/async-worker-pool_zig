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

| Engine / Project | Language | Workload | Throughput | Mean Latency | Memory & Allocator Model |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (32 Workers) | **3.33 M msg/sec** | **299.96 ns** (0.30 µs) | `ArenaAllocator` + Embedded Slabs |
| **`async-worker-pool_zig`** | Zig 0.16 | Raw Single-Ring Stream | **137.96 M msg/sec** | **7.25 ns** | Zero-Allocation `@Vector` SIMD |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **10.50 µs** | Page-Aligned Slabs + Lock-Free Rings |
| **[`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)** | C11 | Raw SPSC Ring | **62.50 M msg/sec** | **16.00 ns** | Lock-Free Vyukov Ring |
| **`awp-rs`** | Rust | Safe FFI Zero-Copy | **0.50 M msg/sec** | **10.80 µs** | RAII `ClaimGuard` over `libawp.a` |

Full benchmark reports and documentation:
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
