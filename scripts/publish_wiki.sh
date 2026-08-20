#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKI_DIR="/tmp/awp_wiki"
DOCS_DIR="$REPO_DIR/docs"

echo "=== Preparing GitHub Wiki for async-worker-pool_zig ==="

# Switch GitHub identity to Dmdv (Mandatory Protocol)
gh auth switch --user Dmdv >/dev/null 2>&1 || true
export GH_TOKEN=$(gh auth token --user Dmdv)
gh auth setup-git >/dev/null 2>&1 || true

rm -rf "$WIKI_DIR"
mkdir -p "$WIKI_DIR"

if git clone https://github.com/Dmdv/async-worker-pool_zig.wiki.git "$WIKI_DIR" 2>/dev/null; then
    echo "✓ Successfully cloned existing wiki repository."
else
    echo "⚠️ Wiki repository not yet initialized on GitHub."
    echo "👉 Please visit https://github.com/Dmdv/async-worker-pool_zig/wiki in your browser and click 'Create the first page' once."
    exit 1
fi

cd "$WIKI_DIR"

# 1. Generate _Sidebar.md (Wiki Table of Contents)
cat << 'EOF' > _Sidebar.md
### 📖 Documentation Index

* [🏠 **Home**](Home)
* [🌟 **Showcase & Live Metrics**](Showcase-and-Live-Metrics)
* [🎬 **Showcase Demo Walkthrough**](Showcase-Demo-Walkthrough)
* [🚀 **Getting Started (Quickstart)**](Getting-Started)

#### 🏛 Architecture & Memory Models
* [System Architecture](System-Architecture)
* [Zero-Copy Memory Models](Zero-Copy-Memory-Models)
* [Memory Models Deep Dive](Memory-Models-Deep-Dive)
* [Hardware Hardening & HugePages](Hardware-Hardening-and-HugePages)
* [Hot-Path Micro-Optimizations](Hot-Path-Optimizations)
* [Allocators Architecture Review](Allocators-Review)

#### ⚡ Concurrency Primitives
* [SPSC Ring Buffers (8B & 64B POD)](SPSC-Ring-Buffers)
* [Bipartite Buffers & BipRing](Bipartite-Buffers-and-BipRing)
* [Multi-Threaded Worker Pool & SIMD](Multi-Threaded-Worker-Pool)
* [Hybrid Trading Reactor & Off-Path](Trading-Reactor-and-Off-Path)
* [End-to-End Trading Loop & Telemetry](End-to-End-Trading-Loop)

#### 🔌 Language Interop (FFI)
* [C ABI Specification](C-ABI-Specification)
* [Rust FFI & Safe RAII Bindings](Rust-FFI-Bindings)

#### 📋 Formal Specifications
* [Phase 1: Hardware Hardening Spec](Phase1-Hardware-Specification)
* [Phase 4: Trading Reactor Spec](Phase4-Reactor-Specification)
* [Phase 5: End-to-End Loop Spec](Phase5-E2E-Specification)

#### 📊 Benchmarks & Roadmap
* [HFT Benchmark Suite & Methodology](HFT-Benchmark-Methodology)
* [Benchmarks Overview & History](Benchmarks-Overview)
* [HFT Evolution Roadmap](HFT-Evolution-Roadmap)
* [Long-Term Evolution Plan](Evolution-Plan)
