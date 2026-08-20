# Performance Benchmarks & C Comparison (Zig 0.16)

High-performance benchmarks for `async-worker-pool_zig` comparing native Zig 0.16 implementation against the C11 engine ([`async-worker-pool`](https://github.com/Dmdv/async-worker-pool)) and Rust bindings (`awp-rs`).

---

## 1. Comparative Results Table (1,000,000 Messages)

| Engine | Language | Workload | Throughput | Latency (Mean) | Allocator / Strategy |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`async-worker-pool_zig`** | Zig 0.16 | Multi-Threaded Async Pool (32 Workers) | **3.33 M msg/sec** | **299.96 ns** (0.30 µs) | `ArenaAllocator` + Embedded Slabs |
| **`async-worker-pool_zig`** | Zig 0.16 | Raw Single-Ring Stream | **137.96 M msg/sec** | **7.25 ns** | Zero-Allocation `@Vector` SIMD |
| **`async-worker-pool`** | C11 | Multi-Threaded Async Pool (32 Workers) | **0.52 M msg/sec** | **10.50 µs** | Page-Aligned Slabs + Lock-Free Rings |
| **`async-worker-pool`** | C11 | Raw SPSC Ring | **62.50 M msg/sec** | **16.00 ns** | Lock-Free Vyukov Ring |
| **`awp-rs`** | Rust | Safe FFI Zero-Copy | **0.50 M msg/sec** | **10.80 µs** | RAII `ClaimGuard` over `libawp.a` |

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
