# Getting Started

This guide walks you through setting up and using **AWP** in both native **Zig** and safe **Rust** projects.

---

## 🛠 Prerequisites

- **Zig:** `0.14.0` or `0.16.0+` (compatible across modern Zig releases)
- **Rust:** `1.75.0+` (for `bindings/rust`)
- **C Compiler:** `clang` / `gcc` (for building shared C libraries)

---

## 1. Native Zig Integration

Add AWP to your `build.zig.zon` or import it directly:

```zig
const std = @import("std");
const awp = @import("async_worker_pool");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Initialize a 64-byte POD Market Data Ring (2048 slots)
    var ring = try awp.SpscRing(awp.BookUpdate64, 2048).init(allocator);
    defer ring.deinit();

    // 2. Producer: Claim slot, write in-place, and commit
    const slot = ring.claim().?;
    slot.* = awp.BookUpdate64{
        .timestamp_ns = awp.nowNs(),
        .bid_price = 10050,
        .ask_price = 10055,
        .bid_size = 500,
        .ask_size = 350,
        .symbol = "BTC-USDT-PERP   ".*,
        .flags = 0x01,
        ._pad = [_]u8{0} ** 15,
    };
    ring.commit();

    // 3. Consumer: Pop typed struct with zero copies
    if (ring.tryPop()) |quote| {
        std.debug.print("Received quote for {s} | Bid: {d} | Ask: {d}\n", .{
            quote.symbol, quote.bid_price, quote.ask_price,
        });
    }
}
```

---

## 2. Safe Rust Integration (`awp-zig-rs`)

Add `awp-zig-rs` to your `Cargo.toml`:

```toml
[dependencies]
awp-zig-rs = { path = "bindings/rust" }
```

### Variable-Length Packet Streaming with RAII Zero-Copy:

```rust
use awp_zig_rs::{BipRing, Result};

fn main() -> Result<()> {
    // 1. Create a BipRing with 256KB payload buffer and 1024-descriptor queue
    let mut ring = BipRing::new(256 * 1024, 1024)?;

    // 2. Producer thread: Stream incoming Ethernet / UDP packets
    let packet_payload = [0x55u8; 1400]; // MTU Ethernet Frame
    let hw_timestamp_ns = 1_700_000_000_000_000_000;
    ring.push_packet(&packet_payload, hw_timestamp_ns);

    // 3. Consumer thread: Pop RAII PacketView
    if let Some(pkt) = ring.pop_packet() {
        println!("Packet timestamp: {} ns", pkt.timestamp_ns());
        println!("Payload length  : {} bytes", pkt.len());
        println!("Header byte     : 0x{:02X}", pkt.payload()[0]);
        // Packet slot in ring is automatically released when `pkt` goes out of scope (Drop RAII)
    }

    Ok(())
}
```

### 64-Byte POD Order Book Quotes:

```rust
use awp_zig_rs::{BookUpdate64, Spsc64Ring, Result};

fn main() -> Result<()> {
    let mut ring = Spsc64Ring::new(2048)?;

    let mut symbol = [0u8; 16];
    symbol[..8].copy_from_slice(b"ETH-USDT");

    let update = BookUpdate64 {
        timestamp_ns: 1_000_001,
        bid_price: 3200_50,
        ask_price: 3200_75,
        bid_size: 100,
        ask_size: 150,
        symbol,
        flags: 1,
        _pad: [0; 15],
    };

    ring.push(&update)?;

    if let Some(quote) = ring.pop() {
        println!("Bid: {} | Ask: {}", quote.bid_price, quote.ask_price);
    }

    Ok(())
}
```

---

## 3. Running Benchmarks & Tests

```bash
# Run all native Zig format, tests, and Rust integration checks
make all

# Run high-performance ReleaseFast benchmark suite
make bench

# Run benchmark regression guard vs baseline
make bench-compare
```
