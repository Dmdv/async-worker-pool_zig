# GitHub Copilot Code Review Instructions: async-worker-pool_zig (Zig 0.16 Core)

You are an expert HFT & Low-Latency Systems Code Reviewer for the `async-worker-pool_zig` project.
When reviewing Pull Requests and code changes, rigorously check for the following standards:

---

## 1. Zig 0.16 Idiomatic Patterns & Memory Invariants
- **Zero Allocations on Hot Path:** Ensure ring buffers, frame slabs, and atomic cells are pre-allocated during initialization. Never use dynamic allocators inside `claim`, `commit`, `tryPush`, `tryPop`, or worker dispatch loops.
- **Explicit Memory Management:** All heap resources must be explicitly freed via `defer allocator.free()` or dedicated `deinit()` functions. Code must pass `std.testing.allocator` leak checks without a single leaked byte.
- **Hardware-Level Precision:** Utilize direct register reads (`cntvct_el0` on ARM64) and branchless SPSC algorithms for sub-microsecond latency.

---

## 2. Comptime & ABI Verification
- **C ABI Safety (`extern struct`):** Ensure structs exposed across FFI boundaries (`Frame`, `Claim`) have compile-time layout assertions (`comptime std.debug.assert`) verifying sizes, offsets, and field alignments.
- **L1 Cacheline Packing:** Verify ring sequence counters are packed into dense cachelines to maximize CPU cache residency.

---

## 3. Rust FFI Wrapper (`awp-zig-rs`)
- Safe Rust wrappers in `bindings/rust` must guarantee RAII safety, zero-copy `write_struct()`, and typed error handling via `AwpError`.
- Ensure `AwpFrame` and `AwpClaim` in `sys.rs` exactly mirror Zig `Frame` and `Claim` byte-for-byte.

---

## 4. Documentation & PR Quality
- All documentation, commit messages, and comments MUST be written in clear English.
- Every PR must pass `make lint` (`zig fmt --check`), `make check` (`zig test`), and `make check-rust` (`cargo test`).
