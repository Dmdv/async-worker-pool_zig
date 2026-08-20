# Rust FFI & Safe RAII Bindings (`awp-zig-rs`)

The **`awp-zig-rs`** crate provides idiomatic, memory-safe, and zero-cost Rust abstractions built on top of the Zig 0.16 C ABI.

---

## 🔒 Memory Safety & Concurrency Contracts

### 1. SPSC Isolation: `Send` without `Sync`
In Single-Producer Single-Consumer queues, allowing multiple threads to call `peek()` or `pop()` concurrently causes data races on internal indices. `awp-zig-rs` strictly enforces:
```rust
unsafe impl Send for BipBuffer {}
// `Sync` is deliberately NOT implemented.
```
This allows transferring ownership of handles across threads while preventing accidental concurrent access through shared references (`&BipBuffer`).

### 2. RAII Zero-Copy Lifetime Guarantees (`PacketView`)
When popping variable-length packets from `BipRing`, Rust ensures memory safety by binding the packet view to the lifetime of the ring:

```rust
pub struct PacketView<'a> {
    ring: &'a mut BipRing,
    payload: &'a [u8],
    desc: sys::PacketDescriptor,
}

impl<'a> Drop for PacketView<'a> {
    fn drop(&mut self) {
        unsafe { sys::awp_zig_bipring_release(self.ring.handle, &self.desc) };
    }
}
```

**Compiler Invariants Enforced:**
1. While `PacketView` is held, no other thread or code can pop or mutate the ring.
2. The memory slice inside `BipBuffer` is guaranteed not to be overwritten by the producer until `PacketView` drops.
3. Drop execution is automatic and cannot be forgotten.

---

## 🛠 Complete Rust Streaming Example

```rust
use awp_zig_rs::{BipRing, Result};

fn main() -> Result<()> {
    let mut ring = BipRing::new(64 * 1024, 512)?;

    // Push packet
    let eth_frame = [0xFF; 256];
    assert!(ring.push_packet(&eth_frame, 1_000_000));

    // RAII Scoped Pop
    {
        let pkt = ring.pop_packet().expect("No packet");
        assert_eq!(pkt.len(), 256);
        assert_eq!(pkt.payload()[0], 0xFF);
        // Slot is automatically released here on drop!
    }

    Ok(())
}
```
