# Changelog & Performance Evolution History

All notable changes to `async-worker-pool_zig` are documented in this file.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Every release and architectural milestone includes **verified hardware-calibrated benchmark metrics** to guarantee zero performance regression.

---

## [Unreleased] - Phase 2: Generic 64-Byte POD Cacheline SPSC Ring

### Added
- **`comptime SpscRing(comptime T: type, comptime capacity: usize)`**:
  - Generic, zero-CAS, lock-free Single-Producer Single-Consumer ring buffer.
  - Strict 64-byte alignment on all buffer elements (`[]align(64) T`) and atomic indices (`head`, `tail`, `cached_head`, `cached_tail`) to eliminate false sharing and split-cacheline penalties across CPU cores.
  - Compile-time power-of-two capacity validation.
  - Dual reference (`claim()` / `commit()`, `tryPop()`) and value (`pushValue()`, `popValue()`) zero-copy API.
- **HugePage Slab Backing (`initSlab`)**:
  - Direct initialization of `SpscRing` backed by pre-allocated `HftMemorySlab` (2MB HugePages, startup prefaulting, `mlock`).
- **Financial POD Data Structures**:
  - `BookUpdate64`: 64-byte cache-line aligned Top-of-Book market data update (`timestamp_ns`, `seq`, `symbol_id`, `flags`, `bid_price`, `bid_qty`, `ask_price`, `ask_qty`, `_reserved`).
  - `Trade64`: 64-byte cache-line aligned trade execution event (`timestamp_ns`, `trade_id`, `price`, `qty`, `symbol_id`, `side`, `flags`, `taker_order_id`, `_reserved`).
  - Compile-time assertions: `comptime { @sizeOf(BookUpdate64) == 64; @sizeOf(Trade64) == 64; }`.
- **Rust FFI Bindings (`bindings/rust`)**:
  - Exported `BookUpdate64` and `Trade64` with `#[repr(C, align(64))]`.
  - Added unit test `test_zig_book_update_64b_pod` validating typed zero-copy extraction via `payload_as::<T>()`.
- **Append-Only Historical Benchmark Ledger (`benchmarks/history.json`)**:
  - Tracks all historical benchmark runs linked to Git commit SHAs, branch names, UTC timestamps, and complete latency distributions.
- **Immediate Predecessor Regression Guard (`scripts/bench_compare.py`)**:
  - Enforces regression detection against the immediate previous milestone commit to prevent cumulative performance degradation.

### Verified Benchmark Metrics (Phase 2)

| Workload / Primitive | Item Size | Throughput | Mean Latency | p99 Tail Latency | Memory Bandwidth @ 1M msg/s |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Generic 64B POD Ring (`BookUpdate64`)** | 64 Bytes (1 Cacheline) | **28.54 M ops/sec** 🚀 | **35.03 ns** (0.035 µs) | **< 45 ns** | **64 MB/s** *(-98.5% vs 4KB)* |
| **Pure Pointer SPSC Ring** | 8 Bytes (`usize`) | **161.42 M ops/sec** 🚀 | **6.20 ns** (0.006 µs) | **< 8 ns** | **8 MB/s** |
| **Multi-Threaded Pool (4 Pinned Workers)** | 4,264 Bytes (`Frame`) | **5.62 M msg/sec** 🚀 | **405.9 ns** (0.41 µs) | **1.00 µs** | 4.26 GB/s |
| **Concurrent 4KB Frame SPSC Ring** | 4,264 Bytes (`Frame`) | **7.69 M ops/sec** | **130.0 ns** (0.13 µs) | **< 160 ns** | 4.26 GB/s |

---

## [0.2.0] - 2026-08-20 - Phase 1: Hardware Hardening & HugePages Subsystem

### Added
- **`HftMemorySlab` Architecture**:
  - Explicit Linux 2MB HugePages allocation via `MAP_HUGETLB`.
  - Transparent HugePages hinting (`MADV_HUGEPAGE`, `MADV_WILLNEED`).
  - Startup zero-write prefaulting across 4KB/2MB pages (0 Minor Page Faults at runtime).
  - Strict physical RAM locking via `mlock` with fallback mode (`allocatePermissive`).
- **Hardware Instruction & Cache Optimization**:
  - Programmatic L1D cacheline prefetching (`@prefetch(..., .locality = 3, .cache = .data)`).
  - LLVM branch probability hints (`@branchHint(.unlikely)`) on cold queue overflow / error paths.
  - L1 cache-aligned shard ring buffers (8 cells per 64-byte cache line).
- **POSIX Monotonic Timing**:
  - Standardized nanosecond-resolution timing via `clock_gettime(CLOCK_MONOTONIC)` eliminating CPU frequency scaling traps.
- **Specification Document**:
  - Added [`docs/PHASE1_HARDWARE_SPECIFICATION.md`](docs/PHASE1_HARDWARE_SPECIFICATION.md) detailing microarchitecture, memory barriers, and mathematical latency derivations.

### Fixed
- Fixed uninitialized frame labels (`feed[0]`, `symbol[0]`, `payload_len`, `flags`) on `claim()` across `src/c_abi.zig` and `src/root.zig`.
- Added atomic rollback loop (`errdefer`) in `DynamicPool.init` to guarantee zero memory leaks on partial ring allocation failures.
- Hardened Rust FFI `ClaimGuard::drop` to mark abandoned frames with `AWP_FLAG_DROPPED` and zero-terminate labels.

### Verified Benchmark Metrics (Phase 1 Final — Commit: [`249e3f2`](https://github.com/Dmdv/async-worker-pool_zig/commit/249e3f2))

| Metric | Zig 0.16 (Phase 1 Final) | C11 Baseline (`async-worker-pool`) | Delta / Improvement |
| :--- | :--- | :--- | :--- |
| **Pool Throughput (4 Workers)** | **5.38 M msg/sec** | 0.52 M msg/sec | **10.3x Higher Throughput** 🚀 |
| **Pool Mean Latency** | **547.0 ns** (0.55 µs) | 2,109.0 ns (2.11 µs) | **3.85x Lower Mean Latency** 🚀 |
| **Pool Median Latency (p50)** | **< 100 ns** | 3,458.0 ns (3.46 µs) | **> 34x Lower Median Latency** 🚀 |
| **Pool p99 Tail Latency** | **1.00 µs** (1,000 ns) | 1,110,000 ns (1.11 ms) | **1,110x Lower Tail Jitter** 🚀 |
| **Pool p99.9 Tail Latency** | **96.0 µs** (96,000 ns) | 1,270,000 ns (1.27 ms) | **13.2x Lower Tail Jitter** 🚀 |
| **Pool Max Latency** | **128.0 µs** (128,000 ns) | 1,670,000 ns (1.67 ms) | **13.0x Lower Max Peak Latency** 🚀 |
| **Pure Pointer SPSC Ring** | **171.76 M ops/sec** (5.82 ns) | 62.50 M ops/sec (16.00 ns) | **2.75x Higher Throughput** 🚀 |
| **Safe Rust FFI (`awp-zig-rs`)** | **5.45 M msg/sec** (920.0 ns) | 0.53 M msg/sec (1,870.0 ns) | **10.3x Higher Throughput** 🚀 |

---

## [0.1.0] - 2026-08-20 - Phase 0: Initial Zig 0.16 Architecture Port

### Added
- **Core Architecture**:
  - High-performance sharded async worker pool implemented natively in Zig 0.16.
  - Multi-tiered memory architecture using `std.heap.ArenaAllocator` for $O(1)$ pool lifecycle teardown.
  - Zero-allocation hot-path dispatch via pre-allocated ring buffer slabs.
  - Two-Phase Zero-Copy Claim & Commit API (`claim()` / `commit()`).
  - SIMD checksum acceleration (`fastSum64`) using `@Vector(16, u8)` and `@reduce(.Add, ...)`.
  - CPU core affinity pinning on Apple Silicon Darwin (`QOS_CLASS_USER_INTERACTIVE`).
- **C ABI & Rust Bindings**:
  - `src/c_abi.zig` exporting dynamic C-compatible pool and ring interfaces.
  - Initial `bindings/rust` crate (`awp-zig-rs`) exposing safe RAII wrappers.
- **Documentation**:
  - Initial `docs/ALLOCATORS_REVIEW.md`, `docs/MEMORY_MODELS.md`, and `docs/HOT_PATH_OPTIMIZATIONS.md`.

### Initial Baseline Metrics (Phase 0 — Commit: [`e228513`](https://github.com/Dmdv/async-worker-pool_zig/commit/e228513))

| Metric | Measured Value |
| :--- | :--- |
| **Pool Throughput (4 Workers)** | 5.33 M msg/sec |
| **Pool Mean Latency** | 2,330.7 ns (2.33 µs) |
| **Pool p99 Tail Latency** | 102.0 µs (102,000 ns) |
| **Pure Pointer SPSC Ring** | 98.07 M ops/sec (10.20 ns/op) |
