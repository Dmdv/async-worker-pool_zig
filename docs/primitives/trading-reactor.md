# Hybrid Trading Reactor & Off-Path Worker Pipeline

Phase 4 introduces the **Hybrid Fast-Path Trading Reactor & Asynchronous Off-Path Pipeline**, decoupling critical tick-to-trade execution from heavy post-trade processing, compliance checks, risk management, and audit logging.

---

## Architecture Topology

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
        ├──► [ DIRECT FAST-PATH EGRESS ] ──► Outbound Gateway (0 Hop, ~247 ns)
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

## Core Invariants

1. **Zero-Lock Critical Path:** `TradingReactor.processTick` executes with zero mutexes, condition variables, atomic CAS loops, or dynamic memory allocations.
2. **Zero-Stall Off-Path Fan-Out:** Fan-out to off-path queues uses non-blocking `claim()` / `commit()`. If an off-path ring is full, the reactor increments an `overrun_count` atomic counter and proceeds immediately, guaranteeing that slow background workers never stall tick-to-trade execution.
3. **Cacheline Isolation:** Producer write state and consumer read state across all off-path rings are padded and aligned to 64 bytes (`align(64)`).

---

## 64-Byte POD OrderSignal64

```zig
pub const OrderSignal64 = extern struct {
    timestamp_ns: u64 align(64) = 0, // 8B: Signal generation timestamp (forces 64B alignment)
    ingress_ts_ns: u64 = 0, // 8B: Ingress market data tick timestamp
    order_id: u64 = 0, // 8B: Unique client order ID
    price: f64 = 0, // 8B: Limit price in ticks
    qty: f64 = 0, // 8B: Order quantity
    symbol_id: u32 = 0, // 4B: Integer ticker identifier
    side: u32 = 0, // 4B: Side (0 = Buy, 1 = Sell)
    action: u32 = 0, // 4B: Action (1 = New, 2 = Cancel, 3 = Replace)
    flags: u32 = 0, // 4B: Flags (0x01 = IOC, 0x02 = PostOnly)
    _reserved: [8]u8 = [_]u8{0} ** 8, // 8B: Padding to exactly 64 bytes
};
```

---

## Rust Integration Example (`awp-zig-rs`)

```rust
use awp_zig_rs::{BookUpdate64, OffPathPipeline, TradingReactor, Result};

fn main() -> Result<()> {
    // 1. Initialize and start the background Off-Path Pipeline
    let mut offpath = OffPathPipeline::new(4096)?;
    offpath.start()?;

    // 2. Initialize the Fast-Path Trading Reactor and bind worker queues
    let mut reactor = TradingReactor::new()?;
    reactor.bind_offpath(&offpath);

    // 3. Process market data ticks at multi-million ticks/sec
    let update = BookUpdate64 {
        timestamp_ns: 1_700_000_000_000_000,
        seq: 101,
        symbol_id: 1,
        flags: 1,
        bid_price: 65_000.0,
        bid_qty: 1.5,
        ask_price: 65_000.5,
        ask_qty: 2.0,
        _reserved: [0; 8],
    };

    if let Some(signal) = reactor.process_tick(&update) {
        println!("Signal generated: Buy {} @ {}", signal.qty, signal.price);
        // Transmit directly to gateway with 0 hops!
    }

    let stats = offpath.stats();
    println!("Processed: Risk={}, Audit={}, Telemetry={}", 
        stats.risk_processed, stats.audit_processed, stats.telemetry_processed);

    Ok(())
}
```
