## Summary of Changes

<!-- Provide a brief, concise summary of the changes introduced in this PR. -->

---

## Key Invariants Checked

- [ ] **Zero-Allocation:** No dynamic heap allocations in hot-path loops or claim/commit functions.
- [ ] **Memory Safety:** Tested clean under `std.testing.allocator` leak detector with zero bytes leaked.
- [ ] **Zig Formatter:** Code formatted and verified via `make lint` (`zig fmt --check`).
- [ ] **Rust FFI:** `awp-zig-rs` tests (`make check-rust`) and benchmark (`make bench-rust`) pass cleanly.
- [ ] **Documentation:** All documentation and tables updated in English.

---

## Test Verification

```bash
# Lint formatting & native unit tests
make lint
make check

# Rust FFI bindings
make check-rust
```
