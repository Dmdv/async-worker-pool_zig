# Performance Benchmarks & C Comparison (Zig 0.16)

High-performance benchmarks for `async-worker-pool_zig` comparing native Zig 0.16 implementation against the C11 engine ([`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)) and Rust bindings (`awp-rs`).

---

## Table of Contents

- [1. Comparative Results Table (1,000,000 Messages)](#1-comparative-results-table-1000000-messages)
- [2. Memory & Allocator Strategy](#2-memory--allocator-strategy)
- [3. Running the Benchmark](#3-running-the-benchmark)

---

## 1. Comparative Results Table (1,000,000 Messages)

| Engine | Language | Workload | Throughput | Median (p50) | p99 Latency | Mean Latency |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (4 Pinned Workers) | **0.19 M msg/sec** 🚀 | **8.71 µs** (8,709 ns) | **45.12 µs** (45,125 ns) | **13.10 µs** (13,098 ns) |
| **`async-worker-pool_zig`** | Zig 0.16 | Pure Pointer SPSC Ring (0 CAS) | **85.18 M ops/sec** 🚀 | **< 12 ns** | **< 15 ns** | **11.74 ns** |
| **`awp-zig-rs`** ([`bindings/rust`](../bindings/rust)) | Rust on Zig 0.16 | Safe Rust FFI Zero-Copy | **0.18 M msg/sec** 🚀 | **9.20 µs** (9,200 ns) | **48.30 µs** (48,300 ns) | **14.20 µs** (14,200 ns) |
| **`async-worker-pool`** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **3.46 µs** (3,458 ns) | **1.11 ms** (1,110,000 ns) | **2.11 µs** (2,109 ns) |
| **`async-worker-pool`** | C11 | Raw SPSC Ring | **62.50 M ops/sec** | **< 16 ns** | **< 20 ns** | **16.00 ns** |
| **`awp-rs`** | Rust on C11 | Safe FFI Zero-Copy (`v0.3.0`) | **0.53 M msg/sec** | **3.35 µs** (3,350 ns) | **1.15 ms** (1,150,000 ns) | **1.87 µs** (1,870 ns) |

---

### Detailed Tail Latencies Breakdown (1,000,000 Messages)

| Percentile | **Zig 0.16 Engine (Phase 1)** | **C11 Engine** (`async-worker-pool`) | Delta / Notes |
| :--- | :--- | :--- | :--- |
| **Min (Hardware Floor)** | **0.75 µs** (750 ns) | **120 ns** (0.120 µs) | Hardware DMA Floor |
| **p50 (Median)** | **8.71 µs** (8,709 ns) | **3.46 µs** (3,458 ns) | Pinned Reactor Loop |
| **p90** | **24.33 µs** (24,333 ns) | **7.17 µs** (7,167 ns) | Hot Cacheline Drain |
| **p99 (Tail)** | **45.12 µs** (45,125 ns) | **379.92 µs** (379,920 ns) | **Zig is 8.4x lower tail jitter** 🚀 |
| **p99.9** | **300.37 µs** (300,375 ns) | **1.27 ms** (1,270,000 ns) | **Zig is 4.2x lower tail jitter** 🚀 |
| **Max** | **1.90 ms** (1,902,500 ns) | **1.63 ms** (1,630,000 ns) | Peak Saturation Bound |
| **Pure SPSC Throughput** | **85.18 Million ops/sec** | **62.50 Million ops/sec** | **Zig is 36.3% faster** 🚀 |

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
