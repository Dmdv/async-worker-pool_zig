# Bipartite Buffers & BipRing (Variable-Length Streaming)

Standard circular ring buffers suffer from **boundary wrap-around fragmentation**: when a variable-length network packet crosses the buffer end boundary, it is split into two disjoint memory chunks, forcing the consumer to allocate temporary memory and perform a reassembly `memcpy`.

AWP implements **Simon Cooke's Lock-Free Bipartite Buffer (`BipBuffer`)** and couples it with a descriptor queue (**`BipRing`**), guaranteeing **100% contiguous virtual-memory views** for all variable-length packets.

---

## Bipartite Memory Wrapping Mechanics

The buffer alternates dynamically between **Region A** (tail of buffer) and **Region B** (head of buffer):

```
1. Initial Sequential Allocations in Region A:
┌───────────────────────────────────────────────────────────┐
│ Packet 1 (1400B) │ Packet 2 (512B) │ [Free Space (600B)]  │
└───────────────────────────────────────────────────────────┘
▲                                                           ▲
read_a = 0                                       write_a = 1912

2. Packet 3 (1400B) arrives. Does not fit in 600B of Region A!
   BipBuffer wraps cleanly to Region B at index 0:
┌───────────────────────────────────────────────────────────┐
│ Packet 3 (1400B) │ [Free] │ P1 (1400B) │ P2 (512B) │ [A]  │
└───────────────────────────────────────────────────────────┘
▲                  ▲        ▲
0: Region B        write_b  read_a (Consumer still reading A)

3. Consumer finishes Region A -> switches to Region B.
   Region B is promoted back to Region A. Zero fragmentation!
```

---

## `BipRing`: Coupling BipBuffer with Descriptors

While `BipBuffer` handles raw byte allocations, **`BipRing(buffer_capacity, descriptor_capacity)`** couples it with a lock-free 16-byte `PacketDescriptor` SPSC ring:

```zig
pub const PacketDescriptor = extern struct {
    timestamp_ns: u64, // Hardware ingress timestamp
    offset: u32,       // Byte offset inside BipBuffer
    len: u32,          // Length of payload
};
```

### Producer Streaming:
```zig
const success = bip_ring.pushPacket(udp_payload, awp.nowNs());
```

### Consumer Zero-Copy Reception & Release:
```zig
if (bip_ring.popPacket()) |pkt| {
    // 1. Process payload in-place (contiguous Zero-Copy view)
    processEthernetFrame(pkt.payload);

    // 2. Safely release slot for writer reuse
    bip_ring.releasePacket(pkt.desc);
}
```

---

## Rust RAII Zero-Copy Safety (`PacketView`)

In Rust, `awp_zig_rs::PacketView<'a>` borrows `&'a mut BipRing`. When the view goes out of scope, its `Drop` implementation automatically notifies the C ABI to release the buffer region:

```rust
if let Some(pkt) = ring.pop_packet() {
    println!("Payload size: {}", pkt.len());
    // Packet memory is strictly protected from writer overwrites while `pkt` is alive.
} // Drop automatically calls awp_zig_bipring_release!
```
