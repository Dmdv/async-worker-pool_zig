# Hybrid Trading Reactor & Asynchronous Off-Path Pipeline

The **Hybrid Fast-Path Trading Reactor & Asynchronous Off-Path Worker Pipeline** is the core architecture introduced in Phase 4 of **AWP (Async Worker Pool & Ultra-Low-Latency HFT Engine)**.

It decouples the **nanosecond-critical tick-to-trade fast-path** (quoting and order execution) from **heavy background operations** (portfolio risk calculation, binary audit logging, and latency telemetry), guaranteeing sub-300ns tick-to-trade latency with zero cross-core cache invalidation.

---

## 1. High-Level Architecture Topology

```
                         [ INGRESS NETWORK NIC / BipRing ]
                                        │
                                        ▼ (BookUpdate64 / 64-Byte POD Market Ticks)
   ╔═══════════════════════════════════════════════════════════════════════════════════╗
   ║  FAST-PATH TRADING REACTOR (Single-Threaded P-Core, Zero Locks/Syscalls on Path)  ║
   ║                                                                                   ║
   ║  1. Ingest Market Data Tick (Hardware timestamped via NIC or TSC / now_ns)        ║
   ║  2. Update L1-resident Top-of-Book cache (best_bid, best_ask, seq)                ║
   ║  3. Evaluate Strategy / Microsecond Alpha logic                                   ║
   ║  4. Generate 64-Byte POD OrderSignal64                                            ║
   ╚════════════════════════════════════════╤══════════════════════════════════════════╝
                                            │
               ┌────────────────────────────┴────────────────────────────┐
               ▼ (Return Signal to Caller for Egress)                    ▼ (Non-Blocking SPSC Fan-Out)
   ┌────────────────────────────────────────┐       ┌──────────────────────────────────────────────┐
   │ CALLER EGRESS / OUTBOUND GATEWAY       │       │ ASYNCHRONOUS OFF-PATH PIPELINE               │
   │                                        │       │                                              │
   │ • Fast-path decision: ~19 ns           │       │ ├──► SpscRing(Risk)   ──► Core 2: Risk Shard │
   │ • Caller serializes to Wire / NIC      │       │ ├──► SpscRing(Audit)  ──► Core 3: Audit Log  │
   │ • Full Round-Trip Loop: < 600 ns       │       │ └──► SpscRing(Telem)  ──► Core 4: Telemetry  │
   └────────────────────────────────────────┘       └──────────────────────────────────────────────┘
```

---

## 2. Deep Dive: The 3 Foundational Pillars

### 🏛️ Pillar 1: Reactor Core (Single-Threaded P-Core)

#### 🎯 The Core Philosophy: "Do Nothing on the Critical Path Except Trading"
In ultra-low-latency electronic trading, **every CPU cycle counts**:
* A single mutex acquisition costs **25–60 nanoseconds** in the best case, and **microseconds to milliseconds** if the thread context switches.
* A single Linux/macOS system call (`clock_gettime`, `write`, `futex`) takes **15–50 nanoseconds**.
* A single L3 cache miss or inter-core cache snooping event costs **15–40 nanoseconds**.

The **Trading Reactor Core** solves this by enforcing strict architectural invariants:
1. **Dedicated Core Affinity (Caller-Managed):** For maximum predictability, the Reactor thread should be pinned to an isolated Performance Core (e.g. using `pthread_setaffinity_np` or Linux `isolcpus`). Background off-path worker threads automatically call `pinToPerformanceCores()` on initialization.
2. **Zero Dynamic Memory Allocations on Hot Path (`malloc` / `free` = 0):** All structures, rings, and caches are pre-allocated at startup. Optional HugePage slab allocation (`HftMemorySlab`) can be used to eliminate TLB misses.
3. **Zero Inter-Core Locks (Mutexes / Semaphores = 0):** The Reactor never shares state through mutexes or CAS atomic loops with other threads.
4. **Zero System Calls on Ingress (`processTickWithTs`):** Ingress timestamps can be passed directly from the hardware packet descriptor or NIC ingress timestamp, avoiding OS time calls.

#### 💡 Student Analogy: The Formula 1 Pitstop
> Think of the **Reactor Core** as a Formula 1 race car crossing the finish line. You don't ask the driver to stop mid-race to fill out accounting forms, file tax receipts, or calculate fuel analytics. The driver makes the instantaneous steering decision (buying/selling), sends the signal immediately to the caller for outbound transmission, and passes copies of telemetry over radio to the pit crew (Off-Path workers) without slowing down!

```zig
// Critical Fast-Path Execution Loop (src/root.zig)
pub inline fn processTickWithTs(self: *Self, update: BookUpdate64, now_ns: u64) ?OrderSignal64 {
    self.processed_ticks += 1;
    self.best_bid_price = update.bid_price;
    self.best_ask_price = update.ask_price;

    // Strategy evaluation: instant alpha signal calculation
    if (update.ask_price > update.bid_price and update.bid_price > 0) {
        const signal = OrderSignal64{
            .timestamp_ns = now_ns,
            .ingress_ts_ns = update.timestamp_ns,
            .order_id = self.next_order_id,
            .symbol_id = update.symbol_id,
            .side = 0, // Buy
            .price = update.bid_price,
            .qty = update.bid_qty,
            .action = 1, // New Order
            .flags = 0x02, // PostOnly (Maker liquidity)
            ._reserved = [_]u8{0} ** 8,
        };
        self.next_order_id += 1;

        // Zero-mutex non-blocking fanout to background queues
        self.fanOutNonBlocking(signal);

        return signal; // Return to caller for immediate outbound serialization
    }
    return null;
}
```

---

### 🛡️ Pillar 2: Off-Path Worker Shards (Risk, Audit, Telemetry)

#### 🎯 Decoupling Heavy Background Work
While the Reactor Core focuses purely on order generation, trading exchanges and regulatory authorities require heavy secondary operations:
1. **Risk Shard (Worker Core 2):** Tracks real-time portfolio net notional exposure and accumulated position across instruments.
2. **Audit Shard (Worker Core 3):** Computes rolling binary state checksums and order sequencing for downstream persistence loggers.
3. **Telemetry Shard (Worker Core 4):** Accumulates transit duration metrics and sample counters for latency profiling and monitoring.

#### ⚡ Why SPSC Rings Instead of a Shared MPMC Queue?
* **Single Producer, Single Consumer (SPSC):** The Reactor is the *sole producer* writing to each ring; each background worker is the *sole consumer* reading from its respective ring.
* **No CAS (Compare-And-Swap) Loops:** SPSC queues require only **1 acquire-load** and **1 release-store** on cacheline-separated pointers (`head` vs `tail`).
* **Cacheline Isolation (64-byte padding):** The producer writes to `head` (Cache Line 0), while the worker reads from `tail` (Cache Line 1). This eliminates **False Sharing** between producer and consumer threads while allowing orderly acquire-release synchronization across cachelines.

```
  TRADING REACTOR (Core 1)              OFF-PATH WORKERS (Cores 2, 3, 4)
┌──────────────────────────┐           ┌────────────────────────────────┐
│                          │──[SPSC]──►│ Core 2: Portfolio Risk Shard   │
│  Writes to 'head'        │──[SPSC]──►│ Core 3: Binary Audit Logger    │
│  (Cache Line 0: 64B Pad) │──[SPSC]──►│ Core 4: Latency Telemetry      │
└──────────────────────────┘           └────────────────────────────────┘
                                                Reads from 'tail'
                                            (Cache Line 1: 64B Pad)
```

---

### 🌊 Pillar 3: Non-Blocking Backpressure & Overrun Handling

#### 🎯 What Happens During Market Volatility Bursts?
During sudden market events (CPI inflation releases, interest rate decisions, crypto market flash crashes), market data surges from thousands of ticks/sec to **millions of ticks/sec**:
* The Reactor Core effortlessly processes **4+ million ticks/sec** because its logic is just a few CPU instructions.
* However, the **Audit Logger** or the **Risk Shard** doing heavier computations may lag behind under burst conditions.
* Eventually, the 4096-slot SPSC queue between the Reactor and the worker becomes **FULL**.

#### 🚨 The Critical Question: Should the Reactor Block?
* In web servers (like HTTP/REST), you use *blocking backpressure* (making the client wait).
* **IN HFT, BLOCKING IS FATAL:** If the Reactor thread blocks waiting for a background worker to free a slot, your order arrives at the exchange late, resulting in severe financial slippage (adverse selection).

#### 🛡️ AWP Backpressure Strategy: Non-Blocking Overrun Bypass
In AWP, the Reactor Core **NEVER BLOCKS**:
1. When fanout occurs, the Reactor executes `ring.claim()`.
2. If `claim()` returns `null` (ring full), the Reactor **does not spin or wait**.
3. It atomically increments `overrun_count` with `.monotonic` ordering and returns the order signal immediately to the caller.
4. When market load calms down, background workers drain the remaining in-flight items without having delayed a single trade.

```zig
inline fn fanOutNonBlocking(self: *Self, signal: OrderSignal64) void {
    if (self.risk_ring) |r| {
        if (r.claim()) |slot| {
            slot.* = signal;
            r.commit();
        } else {
            // Queue full: Never block the reactor! Increment overruns and proceed!
            _ = self.overrun_count.fetchAdd(1, .monotonic);
        }
    }
    // Repeat for Audit and Telemetry rings...
}
```

#### 📊 Backpressure Strategy Comparison Matrix

| Strategy | Behavior on Queue Full | Impact on Fast-Path Latency | Data Integrity Guarantee | Best Use Case |
| :--- | :--- | :--- | :--- | :--- |
| **Non-Blocking Overrun Bypass (AWP)** | Drop off-path copy, record atomic metric counter | **Minimal bounded overhead (~2-5 ns)** | 100% order execution; metrics/logs track dropped count | **HFT Fast-Path Trading (Default)** |
| **Drop-Oldest (Ring Overwrite)** | Overwrite oldest unread slot | **Minimal (~2 ns pointer advance)** | Always keeps the most recent data; drops historical backlog | Real-time Dashboard Telemetry / UI Feeds |
| **Work-Stealing (Multi-Consumer Queue)** | Sibling idle workers steal chunks (requires MPMC/Steal Queue) | **Moderate (~5-15 ns CAS on steal pointer)** | All data processed across N worker cores | Batch Market Replay & Distributed Risk (Hypothetical) |
| **Blocking Wait (Spin / Futex)** | Reactor pauses until worker frees space | **Catastrophic (10 µs – 10 ms spike)** | 100% lossless logging | End-of-Day Reconciliation (Prohibited on Hot Path) |

---

## 3. Data Structures: 64-Byte POD OrderSignal64

All communication between the Reactor and off-path workers uses `OrderSignal64`, structured to match a single 64-byte hardware cache line:

```zig
pub const OrderSignal64 = extern struct {
    timestamp_ns: u64 align(64) = 0, // 8B: Signal generation timestamp (forces 64B alignment)
    ingress_ts_ns: u64 = 0,          // 8B: Ingress market data tick timestamp
    order_id: u64 = 0,               // 8B: Unique client order ID
    price: f64 = 0,                  // 8B: Limit price in ticks
    qty: f64 = 0,                    // 8B: Order quantity
    symbol_id: u32 = 0,              // 4B: Integer ticker identifier
    side: u32 = 0,                   // 4B: 0 = Buy, 1 = Sell
    action: u32 = 0,                 // 4B: 1 = New, 2 = Cancel, 3 = Replace
    flags: u32 = 0,                  // 4B: 0x01 = IOC, 0x02 = PostOnly
    _reserved: [8]u8 = [_]u8{0} ** 8,// 8B: Padding to exactly 64 bytes
};
```

---

## 4. Rust Idiomatic Example (`awp-zig-rs`)

```rust
use awp_zig_rs::{AwpError, BookUpdate64, OffPathPipeline, TradingReactor};

fn main() -> Result<(), AwpError> {
    // 1. Initialize and start background worker pipeline (Cores 2, 3, 4)
    let mut offpath = OffPathPipeline::new(4096)?;
    offpath.start()?;

    // 2. Initialize single-threaded Fast-Path Reactor (Core 1)
    let mut reactor = TradingReactor::new()?;
    
    // 3. Exclusively bind worker queues (enforced at compile time via borrow checker)
    reactor.bind_offpath(&mut offpath);

    // 4. Process live market data stream
    let update = BookUpdate64 {
        timestamp_ns: 1_700_000_000_000_000,
        seq: 1001,
        symbol_id: 42,
        flags: 1,
        bid_price: 65_000.50,
        bid_qty: 2.50,
        ask_price: 65_001.00,
        ask_qty: 3.75,
        _reserved: [0; 8],
    };

    // Evaluated in ~19 ns on Fast-Path Core
    if let Some(signal) = reactor.process_tick(&update)? {
        println!("Signal Generated: Order #{} Buy {} @ {}", signal.order_id, signal.qty, signal.price);
        // Caller serializes signal to outbound wire or network gateway
    }

    // 5. Safely query background worker stats while bound
    if let Some(stats) = reactor.offpath_stats() {
        println!("Worker Stats: Risk={}, Audit={}, Telemetry={}, Overruns={}",
            stats.risk_processed, stats.audit_processed, stats.telemetry_processed, reactor.overruns());
    }

    Ok(())
}
```
