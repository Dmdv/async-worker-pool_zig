# Phase 4 Specification: Hybrid Fast-Path Trading Reactor & Off-Path Pipeline

---

## 1. Executive Summary & Architectural Thesis

In institutional High-Frequency Trading (HFT) and ultra-low-latency market making:
1. **The Critical Path MUST be Single-Threaded & Zero-Hop:** The direct tick-to-trade loop (market data ingestion ➔ strategy logic ➔ order signal generation ➔ gateway transmission) runs exclusively on a single dedicated, isolated CPU Performance Core (P-Core). Any multi-threaded synchronization or mutex locking on this hot path introduces 100–300 ns cacheline bouncing and unpredictable OS scheduling jitter.
2. **Off-Path Ancillary Work MUST be Decoupled via Non-Blocking SPSC Rings:** Post-trade compliance, portfolio risk limit validation, binary audit logging, and telemetry metrics cannot reside on the hot path. They are offloaded to dedicated background worker threads via non-blocking Single-Producer Single-Consumer (SPSC) 64-byte POD rings.
3. **Non-Blocking Backpressure (Zero-Stall Reactor Invariant):** If an off-path worker slows down or experiences an OS context switch, the trading reactor must **never stall**. It publishes signals to off-path queues on a best-effort basis, atomically incrementing an overrun counter when queues are full, while continuing tick-to-trade execution with sub-microsecond determinism.

---

## 2. Architecture & Dataflow Topology

```
[ Ingress NIC / BipRing ]
           │
           ▼  (BookUpdate64 / 64B Market Data Ticks)
 ┌─────────────────────────────────────────────────────────────┐
 │  TRADING REACTOR (Single-Threaded P-Core 1, Zero Locks)     │
 │                                                             │
 │  1. Ingest Market Data Tick (awp.nowNs() timestamped)       │
 │  2. Update Local L1/L2 OrderBook Cache                      │
 │  3. Execute Microsecond Strategy / Alpha Signal Logic       │
 │  4. Generate 64-Byte OrderSignal64                          │
 └──────┬──────────────────────────────────────────────────────┘
        │
        ├──► [ DIRECT FAST-PATH EGRESS ] ──► Outbound Gateway / Exchange Socket (0 Hop)
        │
        ▼ (Non-Blocking SPSC Ring Fan-Out, 0 Mutexes, 0 Allocations)
 ┌─────────────────────────────────────────────────────────────┐
 │  OFF-PATH PIPELINE (Worker Cores 2, 3, 4)                   │
 │                                                             │
 │  ├──► SpscRing(Risk)      ──► Core 2: Real-time Portfolio Risk & Margin
 │  ├──► SpscRing(Audit)     ──► Core 3: Binary FIX/PCAP Persistence Logger
 │  └──► SpscRing(Telemetry) ──► Core 4: Tick-to-Trade Jitter Histograms
 └─────────────────────────────────────────────────────────────┘
```

---

## 3. Data Structures Specification

### `OrderSignal64` (64-Byte Cacheline POD)
```zig
pub const OrderSignal64 = extern struct {
    timestamp_ns: u64 align(64), // 8B: Nanosecond timestamp of signal generation (64B cacheline aligned)
    ingress_ts_ns: u64,          // 8B: Market data ingress tick timestamp
    order_id: u64,               // 8B: Unique client order identifier
    price: f64,                  // 8B: Fixed-point / float price
    qty: f64,                    // 8B: Quantity in base lots
    symbol_id: u32,              // 4B: Integer instrument ID
    side: u32,                   // 4B: 0 = Buy, 1 = Sell
    action: u32,                 // 4B: 1 = New, 2 = Cancel, 3 = Replace
    flags: u32,                  // 4B: 0x01 = IOC, 0x02 = PostOnly, 0x04 = Market
    _reserved: [8]u8,            // 8B: Zero-padding to exactly 64 bytes (1 cache line)
};
```

---

## 4. Concurrency Invariants & Safety Guarantees

1. **Zero-Lock Hot Path:** `TradingReactor.processTick` contains zero mutexes, condition variables, atomic CAS loops, or heap allocations.
2. **Zero-Stall Off-Path Fan-Out:** Fan-out to off-path queues uses non-blocking `claim()` / `commit()`. If an off-path ring is full, the reactor increments `overrun_count` via `.monotonic` / `.release` atomic store and proceeds immediately.
3. **Cacheline Isolation:** Producer write state and consumer read state across all off-path rings are padded and aligned to 64 bytes (`align(64)`).
4. **RAII & FFI Safety:** Off-path pipeline threads are gracefully stopped and joined on destruction. Rust FFI provides safe lifetime wrappers with clean error propagation.
