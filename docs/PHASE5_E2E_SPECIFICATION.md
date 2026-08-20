# Phase 5 Specification: End-to-End Tick-to-Execution Engine & Telemetry

## 1. Goal & Objectives
1. **Full-Path Loopback:** Integrate network ingress, tick-to-order reactor, outbound serialization, simulated match engine, and execution report ingestion.
2. **Deterministic Latency Metrics:** Sub-divide the trading loop into 5 segments with hardware timestamping:
   - `t2o` (Tick-to-Order): $\le 30\text{ ns}$ SLA.
   - `o2w` (Order-to-Wire): $\le 50\text{ ns}$ SLA.
   - `w2a` (Wire-to-Ack): $\le 150\text{ ns}$ SLA.
   - `e2e` (End-to-End Round-Trip): $\le 250\text{ ns}$ SLA.
3. **Cache-Line Aligned Protocol (64B POD):** `ExecutionReport64` and `WireOrderFrame` strictly 64 bytes (`align(64)`).
4. **Multi-Language Parity:** Zero-cost C ABI exports and safe Rust RAII abstractions with 100% test coverage.

---

## 2. Data Structure Layout Guarantees

```
ExecutionReport64 (64 Bytes, align 64)
┌─────────────────────────┬──────────────┬─────────────┐
│ Field                   │ Type         │ Offset / Sz │
├─────────────────────────┼──────────────┼─────────────┤
│ timestamp_ns            │ u64          │ 0   (8B)    │
│ order_id                │ u64          │ 8   (8B)    │
│ exec_id                 │ u64          │ 16  (8B)    │
│ fill_price              │ f64          │ 24  (8B)    │
│ fill_qty                │ f64          │ 32  (8B)    │
│ leaves_qty              │ f64          │ 40  (8B)    │
│ match_ts_ns             │ u64          │ 48  (8B)    │
│ symbol_id               │ u32          │ 56  (4B)    │
│ status                  │ ExecStatus   │ 60  (4B)    │
└─────────────────────────┴──────────────┴─────────────┘
```

---

## 3. C ABI & FFI Interface

| Function | Return Type | Description |
| :--- | :--- | :--- |
| `awp_zig_mock_matcher_create(capacity, *out)` | `c_int` | Initialize in-memory matching engine |
| `awp_zig_mock_matcher_start(matcher)` | `c_int` | Start matching worker thread |
| `awp_zig_mock_matcher_stop(matcher)` | `void` | Stop worker thread safely |
| `awp_zig_mock_matcher_push_order(matcher, *order)` | `c_int` | Push order signal into matcher |
| `awp_zig_mock_matcher_pop_report(matcher, *report)`| `c_int` | Pop matched execution report |
| `awp_zig_reactor_on_execution(reactor, *report)` | `c_int` | Process fill & update portfolio state |
| `awp_zig_reactor_get_position(reactor, *pos, *notional, *acked)` | `c_int` | Query portfolio position |

---

## 4. Verification & Hard SLA Gates

* **Unit Tests:** `zig test src/root.zig -lc` (12/12 passing).
* **Rust Tests:** `cargo test` in `bindings/rust` (7/7 passing).
* **CI Regression SLA Gate:** `python3 scripts/bench_compare.py` enforcing `t2o_mean_ns <= 35.0 ns` and `e2e_roundtrip_mean_ns <= 250.0 ns`.
