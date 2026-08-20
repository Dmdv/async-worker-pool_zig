# AWP (Async Worker Pool & Ultra-Low-Latency HFT Engine)

**`async-worker-pool_zig`** is an ultra-low-latency, zero-allocation concurrency engine and memory-pipelining toolkit written in **Zig 0.16** with a zero-cost **C ABI** and safe, idiomatic **Rust FFI bindings** (`awp-zig-rs`).

Engineered specifically for High-Frequency Trading (HFT), market data processing, and real-time execution pipelines, AWP delivers sub-microsecond determinism, microarchitectural cacheline isolation, and zero page-fault guarantees.

---

## Core Architecture Pipeline & Workload Specialization

AWP provides three specialized, complementary architectural primitives designed for distinct stages of an ultra-low-latency HFT pipeline:

```
[ NIC / Kernel-Bypass UDP Feed ]
               │
               ▼  (Variable-Length Raw Network Packets: 64B – 1500B MTU)
       ┌──────────────┐
       │ 1. BipRing   │  ➔ Zero-Copy Bipartite Buffer (No wrap split, ~8.52 GB/s Bandwidth)
       └──────┬───────┘
              │ (Exchange Protocol Parser: ITCH / SBE / FAST)
              ▼
       ┌───────────────────────────┐
       │ 2. SpscRing(BookUpdate64) │  ➔ 64-Byte Cacheline POD Ring (35.03 ns Single-Hop Latency)
       └──────┬────────────────────┘
              │ (Matching Engine & Signal Generation)
              ▼
       ┌───────────────────────────┐
       │ 3. Multi-Threaded Pool    │  ➔ Pinned Worker Pool for Risk Controls, FIX Logging & SIMD
       └───────────────────────────┘
```

### Detailed Primitive Specialization & Problem Solving

#### 1. `BipRing` & `BipBuffer` (Variable-Length Network Ingress)
* **Role:** High-throughput streaming of arbitrary-length UDP packets, Ethernet frames, and PCAP data (64 bytes to 1500 bytes MTU).
* **The Problem:** Standard circular ring buffers split packets that cross the end-of-buffer boundary into two disjoint slices, forcing the consumer to allocate temporary memory and perform a copy (`memcpy`) to reconstruct the packet. Naive fixed-slot queues allocate 4KB per slot, wasting 98% of buffer capacity on 64-byte packets.
* **The AWP Solution:** Simon Cooke's lock-free bipartite buffer manages two dynamic contiguous regions (Region A and Region B) coupled with a 16-byte `PacketDescriptor` SPSC ring, guaranteeing **100% contiguous zero-copy virtual slices** at **14.21 Million pkts/sec** (70.38 ns transit latency, **~8.52 GB/s** data throughput).

#### 2. `SpscRing(T, capacity)` (Core-to-Core Market Data Transport)
* **Role:** Nanosecond-grade transmission of typed market data events and order book updates between CPU cores.
* **Specializations:**
  - **`SpscRing(*Task)` (8-Byte Pointers):** Pure pointer dispatch achieving **171.76 Million ops/sec** at **5.82 ns** hop latency.
  - **`SpscRing(BookUpdate64)` (64-Byte Cacheline POD):** Order book quotes and trade prints (`align(64)`) achieving **28.54 Million ops/sec** at **35.03 ns** hop latency.
* **The AWP Solution:** Zero runtime allocations, strict 64-byte cacheline isolation eliminating False Sharing, 2MB HugePage slab backing, and 0 CAS atomic acquire-release ordering.

#### 3. `WorkerPool` / `DynamicPool` (Multi-Threaded Execution & SIMD)
* **Role:** Asynchronous parallel task execution for background analytics, risk monitoring, FIX persistence, and vectorized batch math.
* **The AWP Solution:** Sharded lock-free rings across worker threads pinned to Apple Silicon P-cores / Linux NUMA cores, SIMD-accelerated payload validation (`fastSum64` via ARM NEON / AVX-512), and $O(1)$ memory teardown via `std.heap.ArenaAllocator`.

---

### Safe Rust FFI Abstractions (`awp-zig-rs`)

All core primitives are fully exposed and memory-safe in Rust:
1. `awp_zig_rs::TradingReactor` & `awp_zig_rs::OffPathPipeline` (Phase 4 Fast-Path Reactor & Off-Path Worker Pipeline)
2. `awp_zig_rs::BipRing` / `awp_zig_rs::BipBuffer` (with RAII `PacketView` zero-copy lifetime guards)
3. `awp_zig_rs::Spsc64Ring` / `BookUpdate64` / `Trade64` / `OrderSignal64`
4. `awp_zig_rs::WorkerPool`

---

## Microarchitectural Guarantees

- **Zero-Allocation Hot Path:** Zero `malloc`/`free` calls during streaming.
- **2MB HugePages & Transparent HugePages:** Dedicated `HftMemorySlab` with `MAP_HUGETLB`, `MADV_HUGEPAGE`, and runtime prefaulting guaranteeing **0 Minor Page Faults**.
- **Cacheline Isolation:** Strict 64-byte cacheline separation (`align(64)`) separating producer write indices and consumer read indices to eliminate False Sharing.
- **Lock-Free Concurrency (0 CAS):** Single-producer single-consumer rings with acquire-release atomic ordering, avoiding expensive CAS retry loops.
- **Hardware Timestamping:** Monotonic POSIX `clock_gettime(CLOCK_MONOTONIC)` timing eliminating frequency scaling traps across modern multicore CPUs.

---

## Documentation Directory

- [**Getting Started**](getting-started/quickstart.md) — Quickstart guides for Zig and Rust.
- [**System Architecture**](architecture/overview.md) — Core dataflow and component interaction.
- [**Zero-Copy Memory Models**](architecture/memory-models.md) — Memory topologies and cacheline layouts.
- [**Hybrid Trading Reactor**](primitives/trading-reactor.md) — Fast-path execution & non-blocking off-path worker pipeline.
- [**SPSC Ring Buffers**](primitives/spsc-ring.md) — Deep dive into 8B and 64B lock-free queues.
- [**Bipartite Buffer & BipRing**](primitives/bip-buffer.md) — Simon Cooke bipartite streaming algorithm.
- [**Worker Pool & SIMD**](primitives/worker-pool.md) — Multi-threaded execution and SIMD dispatch.
- [**Hardware Hardening**](primitives/hugepages-slab.md) — 2MB HugePages, prefaulting, and memory locking.
- [**C ABI Specification**](ffi/c-abi.md) — Low-level C headers and binary interface.
- [**Rust FFI Bindings**](ffi/rust-bindings.md) — Safe Rust crate `awp-zig-rs` and RAII Zero-Copy views.
- [**Benchmark Suite**](benchmarks/benchmark-suite.md) — Benchmarking methodology and automated regression guard.
