# AWP (Async Worker Pool & Ultra-Low-Latency HFT Engine)

**`async-worker-pool_zig`** is an ultra-low-latency, zero-allocation concurrency engine and memory-pipelining toolkit written in **Zig 0.16** with a zero-cost **C ABI** and safe, idiomatic **Rust FFI bindings** (`awp-zig-rs`).

Engineered specifically for High-Frequency Trading (HFT), market data processing, and real-time execution pipelines, AWP delivers sub-microsecond determinism, microarchitectural cacheline isolation, and zero page-fault guarantees.

---

## ⚡ Core Performance Pillars

AWP provides three specialized, complementary architectural primitives designed for distinct layers of the HFT pipeline:

```
[ NIC / Kernel-Bypass UDP Ingress ]
                │
                ▼  (Variable-Length Network Frames 64B–1500B MTU)
        ┌──────────────┐
        │ 1. BipRing   │  ➔ Zero-Copy Bipartite Buffer (~8.52 GB/s Bandwidth)
        └──────┬───────┘
               │ (ITCH / SBE / FAST Protocol Parsing)
               ▼
        ┌───────────────────────────┐
        │ 2. SpscRing(BookUpdate64) │  ➔ 64-Byte Cacheline POD Ring (35 ns Hop Latency)
        └──────┬────────────────────┘
               │ (Matching Engine & Signal Execution)
               ▼
        ┌───────────────────────────┐
        │ 3. Multi-Threaded Pool    │  ➔ Pinned Worker Pool + SIMD Vectorization
        └───────────────────────────┘
```

1. **Network Packet Ingress (`BipRing` & `BipBuffer`):**
   - Lock-free Simon Cooke Bipartite Buffer coupled with a 16-byte `PacketDescriptor` SPSC ring.
   - Streams arbitrary packet sizes (64B to 1500B MTU) with **0 memory fragmentation** and **0 split-wrap reassembly `memcpy`**.
   - Achieves **`14.21 Million packets/sec`** at **`70.38 ns`** transit latency (**`8.52 GB/s`** effective data throughput).

2. **Market Data Streaming (`SpscRing<T>` & `BookUpdate64`):**
   - Cacheline-dense 64-byte POD market data structures (`BookUpdate64`, `Trade64`).
   - Slashes memory bus traffic by **98.5%** compared to naive frame allocations, achieving **`28.54 Million ops/sec`** at **`35.03 ns`** single-hop latency.
   - Pure pointer SPSC transfers achieve **`171.76 Million ops/sec`** at **`5.82 ns`** single-hop latency.

3. **Multi-Threaded Worker Pool & SIMD Dispatch:**
   - Sharded lock-free work distribution across Apple Silicon P-cores / Linux NUMA cores.
   - Hardware-accelerated payload validation using `@Vector(16, u8)` and `@reduce(.Add, ...)`.
   - Delivers **`5.38 Million tasks/sec`** at **`547.0 ns`** mean latency and **`1.00 µs`** p99 tail jitter.

---

## 🏛️ Microarchitectural Guarantees

- **Zero-Allocation Hot Path:** Zero `malloc`/`free` calls during streaming.
- **2MB HugePages & Transparent HugePages:** Dedicated `HftMemorySlab` with `MAP_HUGETLB`, `MADV_HUGEPAGE`, and runtime prefaulting guaranteeing **0 Minor Page Faults**.
- **Cacheline Isolation:** Strict 64-byte cacheline separation (`align(64)`) separating producer write indices and consumer read indices to eliminate False Sharing.
- **Lock-Free Concurrency (0 CAS):** Single-producer single-consumer rings with acquire-release atomic ordering, avoiding expensive CAS retry loops.
- **Hardware Timestamping:** Monotonic POSIX `clock_gettime(CLOCK_MONOTONIC)` timing eliminating frequency scaling traps across modern multicore CPUs.

---

## 📦 Documentation Directory

- [**Getting Started**](getting-started/quickstart.md) — Quickstart guides for Zig and Rust.
- [**System Architecture**](architecture/overview.md) — Core dataflow and component interaction.
- [**Zero-Copy Memory Models**](architecture/memory-models.md) — Memory topologies and cacheline layouts.
- [**SPSC Ring Buffers**](primitives/spsc-ring.md) — Deep dive into 8B and 64B lock-free queues.
- [**Bipartite Buffer & BipRing**](primitives/bip-buffer.md) — Simon Cooke bipartite streaming algorithm.
- [**Worker Pool & SIMD**](primitives/worker-pool.md) — Multi-threaded execution and SIMD dispatch.
- [**Hardware Hardening**](primitives/hugepages-slab.md) — 2MB HugePages, prefaulting, and memory locking.
- [**C ABI Specification**](ffi/c-abi.md) — Low-level C headers and binary interface.
- [**Rust FFI Bindings**](ffi/rust-bindings.md) — Safe Rust crate `awp-zig-rs` and RAII Zero-Copy views.
- [**Benchmark Suite**](benchmarks/benchmark-suite.md) — Benchmarking methodology and automated regression guard.
