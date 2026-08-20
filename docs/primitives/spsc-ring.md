# SPSC Ring Buffers (8B Pointers & 64B POD)

The Single-Producer Single-Consumer (SPSC) lock-free ring is the core inter-thread transport primitive in AWP.

---

## ⚡ Comptime-Parameterized Generic Ring

In Zig, `SpscRing(T, capacity)` is parameterized at compile time:

```zig
pub fn SpscRing(comptime T: type, comptime capacity: usize) type
```

### Key Invariants:
1. **Power-of-Two Capacity:** Enforces `capacity & (capacity - 1) == 0`, allowing bitwise AND masking (`idx & mask`) instead of expensive modulo division (`idx % capacity`).
2. **Cacheline Isolation:** Head and tail indices reside on separate 64-byte aligned cachelines.
3. **Local Shadow Caching:** The producer maintains a local `cached_tail`, and the consumer maintains a local `cached_head`. Atomic loads across threads only occur when the local buffer window is exhausted.

---

## 🛠 Two-Phase Zero-Copy API

Rather than copying data into the queue by value, AWP provides a **Two-Phase Claim & Commit** interface:

```zig
// 1. Producer claims a mutable pointer to the next slot in the ring
if (ring.claim()) |slot_ptr| {
    // Write directly into ring memory (Zero-Copy)
    slot_ptr.timestamp_ns = awp.nowNs();
    slot_ptr.bid_price = 10050;
    
    // Commit the slot, publishing it to consumer with Release semantics
    ring.commit();
}
```

### Consumer Extraction:
```zig
// 2. Consumer checks for available items with Acquire semantics
if (ring.tryPop()) |item| {
    processQuote(item);
}
```

---

## 📊 Performance Benchmark Comparison

| Data Structure | Payload Size | Throughput | Mean Latency | Hop Period |
| :--- | :--- | :--- | :--- | :--- |
| **Pure Pointer Ring** | **8 Bytes** | **171.76 M ops/sec** 🚀 | **5.82 ns** | 5.82 ns |
| **64-Byte POD Ring** (`BookUpdate64`) | **64 Bytes** | **28.54 M ops/sec** 🚀 | **35.03 ns** | 35.03 ns |
| **Legacy 4KB Frame Ring** | **4,096 Bytes** | 62.50 M ops/sec | 16.00 ns | 16.00 ns |
