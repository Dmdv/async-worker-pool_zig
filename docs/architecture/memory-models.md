# Zero-Copy Memory Models & Cache Hierarchy

High-Frequency Trading architectures require strict alignment with modern CPU memory hierarchies. AWP guarantees optimal memory throughput by strictly segregating producer and consumer states across distinct 64-byte L1 cache lines.

---

## 🛑 The False Sharing Problem

In multi-threaded architectures, when two CPU cores read and write variables situated on the **same 64-byte cache line**, the CPU cache coherency protocol (MESI / MOESI) triggers constant cache-line invalidation cycles. This phenomenon—**False Sharing**—degrades performance by up to 10–20x.

```
❌ UNPADDED QUEUE (Severe Cacheline Bouncing):
┌──────────────────────────────────────────────────────────────┐
│ Core 0 (Producer): write_idx  │  Core 1 (Consumer): read_idx │  <-- 64 Bytes (Shared Line)
└──────────────────────────────────────────────────────────────┘
                              ▲
                 Constant MESI Invalidation Storm!
```

```
✅ AWP CACHELINE ISOLATION (Zero False Sharing):
┌──────────────────────────────────────────────────────────────┐
│ Cache Line 0 (align(64)): write_offset, write_a, cached_read │  <-- Exclusively owned by Core 0
├──────────────────────────────────────────────────────────────┤
│ Cache Line 1 (align(64)): read_offset, read_a, cached_write  │  <-- Exclusively owned by Core 1
└──────────────────────────────────────────────────────────────┘
```

---

## 🔒 Memory Ordering Semantics

AWP relies on standard **Acquire-Release** synchronization semantics, completely eliminating costly Compare-And-Swap (`cmpxchg`) loops and memory barriers (`mfence`):

| Operation | Atomic Ordering | Explanation |
| :--- | :--- | :--- |
| **Local Index Read** | `.monotonic` | Reading an index owned by the current thread incurs 0 synchronization overhead. |
| **Cached Foreign Index** | Non-atomic | Local private register variable used to check available queue space without polling atomic memory. |
| **Foreign Index Refresh** | `.acquire` | Synchronizes with the remote thread's store, ensuring memory writes prior to the release are visible. |
| **Index Commit** | `.release` | Ensures all payload writes are globally visible before publishing the new index. |

---

## 📐 Memory Alignment of Core Structures

### `PacketDescriptor` (16 Bytes, Aligned to 16)
```zig
pub const PacketDescriptor = extern struct {
    timestamp_ns: u64, // Ingress hardware nanosecond timestamp
    offset: u32,       // Byte offset inside BipBuffer
    len: u32,          // Length of contiguous payload slice
};
```

### `BookUpdate64` (Exactly 64 Bytes = 1 L1 Cacheline)
```zig
pub const BookUpdate64 = extern struct {
    timestamp_ns: u64, // 8 bytes
    bid_price: i64,    // 8 bytes
    ask_price: i64,    // 8 bytes
    bid_size: u32,     // 4 bytes
    ask_size: u32,     // 4 bytes
    symbol: [16]u8,    // 16 bytes
    flags: u8,         // 1 byte
    _pad: [15]u8,      // 15 bytes -> Total: 64 Bytes
};
```
