# Table of contents

* [Introduction](README.md)
* [Showcase & Live Metrics](SHOWCASE.md)
* [Getting Started](getting-started/quickstart.md)

## Core Architecture
* [System Architecture & Dataflow](architecture/overview.md)
* [Zero-Copy Memory Models](architecture/memory-models.md)
* [Hardware Hardening & HugePages](primitives/hugepages-slab.md)

## Concurrency Primitives
* [SPSC Ring Buffers (8B & 64B POD)](primitives/spsc-ring.md)
* [Bipartite Buffers & BipRing](primitives/bip-buffer.md)
* [Multi-Threaded Worker Pool & SIMD](primitives/worker-pool.md)
* [Hybrid Trading Reactor & Off-Path](primitives/trading-reactor.md)
* [End-to-End Tick-to-Execution Engine](primitives/e2e-trading-loop.md)

## Language Interoperability
* [C ABI Specification](ffi/c-abi.md)
* [Rust FFI & Safe RAII Bindings](ffi/rust-bindings.md)

## Specifications
* [Phase 4: Trading Reactor Specification](PHASE4_REACTOR_SPECIFICATION.md)
* [Phase 5: End-to-End Specification](PHASE5_E2E_SPECIFICATION.md)

## Benchmarks & Performance
* [HFT Benchmark Methodology](benchmarks/benchmark-suite.md)
* [Evolution Timeline & History](HFT_EVOLUTION_ROADMAP.md)

