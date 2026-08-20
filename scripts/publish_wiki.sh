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

if git clone "https://Dmdv:${GH_TOKEN}@github.com/Dmdv/async-worker-pool_zig.wiki.git" "$WIKI_DIR" 2>/dev/null; then
    echo "✓ Successfully cloned existing wiki repository."
else
    echo "⚠️ Wiki repository not yet initialized on GitHub."
    echo "👉 Please visit https://github.com/Dmdv/async-worker-pool_zig/wiki in your browser and click 'Create the first page' once."
    exit 1
fi

cd "$WIKI_DIR"

# 1. Generate _Sidebar.md
cat > _Sidebar.md << 'SIDEBAR_EOF'
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
SIDEBAR_EOF

# Generate _Footer.md
cat > _Footer.md << 'FOOTER_EOF'
---
*AWP (Async Worker Pool & Ultra-Low-Latency HFT Engine in Zig 0.16 & Rust) — Maintained by [Dmdv](https://github.com/Dmdv/async-worker-pool_zig)*
FOOTER_EOF

# 2. Copy all documentation pages
cp "$DOCS_DIR/README.md" "$WIKI_DIR/Home.md"
cp "$DOCS_DIR/SHOWCASE.md" "$WIKI_DIR/Showcase-and-Live-Metrics.md"
[ -f "$DOCS_DIR/showcase-demo.md" ] && cp "$DOCS_DIR/showcase-demo.md" "$WIKI_DIR/Showcase-Demo-Walkthrough.md"
cp "$DOCS_DIR/getting-started/quickstart.md" "$WIKI_DIR/Getting-Started.md"
cp "$DOCS_DIR/architecture/overview.md" "$WIKI_DIR/System-Architecture.md"
cp "$DOCS_DIR/architecture/memory-models.md" "$WIKI_DIR/Zero-Copy-Memory-Models.md"
[ -f "$DOCS_DIR/MEMORY_MODELS.md" ] && cp "$DOCS_DIR/MEMORY_MODELS.md" "$WIKI_DIR/Memory-Models-Deep-Dive.md"
cp "$DOCS_DIR/primitives/hugepages-slab.md" "$WIKI_DIR/Hardware-Hardening-and-HugePages.md"
[ -f "$DOCS_DIR/PHASE1_HARDWARE_SPECIFICATION.md" ] && cp "$DOCS_DIR/PHASE1_HARDWARE_SPECIFICATION.md" "$WIKI_DIR/Phase1-Hardware-Specification.md"
cp "$DOCS_DIR/primitives/spsc-ring.md" "$WIKI_DIR/SPSC-Ring-Buffers.md"
cp "$DOCS_DIR/primitives/bip-buffer.md" "$WIKI_DIR/Bipartite-Buffers-and-BipRing.md"
cp "$DOCS_DIR/primitives/worker-pool.md" "$WIKI_DIR/Multi-Threaded-Worker-Pool.md"
cp "$DOCS_DIR/primitives/trading-reactor.md" "$WIKI_DIR/Trading-Reactor-and-Off-Path.md"
[ -f "$DOCS_DIR/PHASE4_REACTOR_SPECIFICATION.md" ] && cp "$DOCS_DIR/PHASE4_REACTOR_SPECIFICATION.md" "$WIKI_DIR/Phase4-Reactor-Specification.md"
[ -f "$DOCS_DIR/primitives/e2e-trading-loop.md" ] && cp "$DOCS_DIR/primitives/e2e-trading-loop.md" "$WIKI_DIR/End-to-End-Trading-Loop.md"
[ -f "$DOCS_DIR/PHASE5_E2E_SPECIFICATION.md" ] && cp "$DOCS_DIR/PHASE5_E2E_SPECIFICATION.md" "$WIKI_DIR/Phase5-E2E-Specification.md"
[ -f "$DOCS_DIR/HOT_PATH_OPTIMIZATIONS.md" ] && cp "$DOCS_DIR/HOT_PATH_OPTIMIZATIONS.md" "$WIKI_DIR/Hot-Path-Optimizations.md"
[ -f "$DOCS_DIR/ALLOCATORS_REVIEW.md" ] && cp "$DOCS_DIR/ALLOCATORS_REVIEW.md" "$WIKI_DIR/Allocators-Review.md"
cp "$DOCS_DIR/ffi/c-abi.md" "$WIKI_DIR/C-ABI-Specification.md"
cp "$DOCS_DIR/ffi/rust-bindings.md" "$WIKI_DIR/Rust-FFI-Bindings.md"
[ -f "$DOCS_DIR/BENCHMARKS.md" ] && cp "$DOCS_DIR/BENCHMARKS.md" "$WIKI_DIR/Benchmarks-Overview.md"
cp "$DOCS_DIR/benchmarks/benchmark-suite.md" "$WIKI_DIR/HFT-Benchmark-Methodology.md"
cp "$DOCS_DIR/HFT_EVOLUTION_ROADMAP.md" "$WIKI_DIR/HFT-Evolution-Roadmap.md"
[ -f "$DOCS_DIR/EVOLUTION_PLAN.md" ] && cp "$DOCS_DIR/EVOLUTION_PLAN.md" "$WIKI_DIR/Evolution-Plan.md"

# Copy images
mkdir -p "$WIKI_DIR/images"
if [ -d "$DOCS_DIR/images" ]; then
    cp -r "$DOCS_DIR/images/"* "$WIKI_DIR/images/" 2>/dev/null || true
fi

# 3. Transform relative markdown links to Wiki links
PYTHON_BIN="python3"
if [ -f "$REPO_DIR/venv/bin/python" ]; then
    PYTHON_BIN="$REPO_DIR/venv/bin/python"
elif [ -f "$REPO_DIR/.venv/bin/python" ]; then
    PYTHON_BIN="$REPO_DIR/.venv/bin/python"
fi

"$PYTHON_BIN" - << 'PY_TRANSFORM'
import os
import re

wiki_dir = "/tmp/awp_wiki"
replacements = {
    r'SHOWCASE\.md': 'Showcase-and-Live-Metrics',
    r'docs/SHOWCASE\.md': 'Showcase-and-Live-Metrics',
    r'showcase-demo\.md': 'Showcase-Demo-Walkthrough',
    r'docs/showcase-demo\.md': 'Showcase-Demo-Walkthrough',
    r'getting-started/quickstart\.md': 'Getting-Started',
    r'docs/getting-started/quickstart\.md': 'Getting-Started',
    r'architecture/overview\.md': 'System-Architecture',
    r'docs/architecture/overview\.md': 'System-Architecture',
    r'architecture/memory-models\.md': 'Zero-Copy-Memory-Models',
    r'docs/architecture/memory-models\.md': 'Zero-Copy-Memory-Models',
    r'MEMORY_MODELS\.md': 'Memory-Models-Deep-Dive',
    r'docs/MEMORY_MODELS\.md': 'Memory-Models-Deep-Dive',
    r'primitives/hugepages-slab\.md': 'Hardware-Hardening-and-HugePages',
    r'docs/primitives/hugepages-slab\.md': 'Hardware-Hardening-and-HugePages',
    r'PHASE1_HARDWARE_SPECIFICATION\.md': 'Phase1-Hardware-Specification',
    r'docs/PHASE1_HARDWARE_SPECIFICATION\.md': 'Phase1-Hardware-Specification',
    r'primitives/spsc-ring\.md': 'SPSC-Ring-Buffers',
    r'docs/primitives/spsc-ring\.md': 'SPSC-Ring-Buffers',
    r'primitives/bip-buffer\.md': 'Bipartite-Buffers-and-BipRing',
    r'docs/primitives/bip-buffer\.md': 'Bipartite-Buffers-and-BipRing',
    r'primitives/worker-pool\.md': 'Multi-Threaded-Worker-Pool',
    r'docs/primitives/worker-pool\.md': 'Multi-Threaded-Worker-Pool',
    r'primitives/trading-reactor\.md': 'Trading-Reactor-and-Off-Path',
    r'docs/primitives/trading-reactor\.md': 'Trading-Reactor-and-Off-Path',
    r'PHASE4_REACTOR_SPECIFICATION\.md': 'Phase4-Reactor-Specification',
    r'docs/PHASE4_REACTOR_SPECIFICATION\.md': 'Phase4-Reactor-Specification',
    r'primitives/e2e-trading-loop\.md': 'End-to-End-Trading-Loop',
    r'docs/primitives/e2e-trading-loop\.md': 'End-to-End-Trading-Loop',
    r'PHASE5_E2E_SPECIFICATION\.md': 'Phase5-E2E-Specification',
    r'docs/PHASE5_E2E_SPECIFICATION\.md': 'Phase5-E2E-Specification',
    r'HOT_PATH_OPTIMIZATIONS\.md': 'Hot-Path-Optimizations',
    r'docs/HOT_PATH_OPTIMIZATIONS\.md': 'Hot-Path-Optimizations',
    r'ALLOCATORS_REVIEW\.md': 'Allocators-Review',
    r'docs/ALLOCATORS_REVIEW\.md': 'Allocators-Review',
    r'ffi/c-abi\.md': 'C-ABI-Specification',
    r'docs/ffi/c-abi\.md': 'C-ABI-Specification',
    r'ffi/rust-bindings\.md': 'Rust-FFI-Bindings',
    r'docs/ffi/rust-bindings\.md': 'Rust-FFI-Bindings',
    r'BENCHMARKS\.md': 'Benchmarks-Overview',
    r'docs/BENCHMARKS\.md': 'Benchmarks-Overview',
    r'benchmarks/benchmark-suite\.md': 'HFT-Benchmark-Methodology',
    r'docs/benchmarks/benchmark-suite\.md': 'HFT-Benchmark-Methodology',
    r'docs/HFT_EVOLUTION_ROADMAP\.md': 'HFT-Evolution-Roadmap',
    r'HFT_EVOLUTION_ROADMAP\.md': 'HFT-Evolution-Roadmap',
    r'EVOLUTION_PLAN\.md': 'Evolution-Plan',
    r'docs/EVOLUTION_PLAN\.md': 'Evolution-Plan',
    r'docs/README\.md': 'Home',
    r'README\.md': 'Home',
}

img_replacement = {
    r'docs/images/': 'https://raw.githubusercontent.com/Dmdv/async-worker-pool_zig/master/docs/images/',
    r'images/': 'https://raw.githubusercontent.com/Dmdv/async-worker-pool_zig/master/docs/images/',
}

for root, _, files in os.walk(wiki_dir):
    for f in files:
        if f.endswith(".md"):
            p = os.path.join(root, f)
            with open(p, "r", encoding="utf-8") as file:
                content = file.read()
            for pattern, target in replacements.items():
                content = re.sub(r'(\(|\[)' + pattern + r'(\)|\#|\s)', r'\1' + target + r'\2', content)
            for pattern, target in img_replacement.items():
                content = content.replace(pattern, target)
            with open(p, "w", encoding="utf-8") as file:
                file.write(content)
print("Processed wiki links and assets successfully.")
PY_TRANSFORM

# 4. Commit and Push to Wiki repository
git config user.name "Dmdv"
git config user.email "805238+Dmdv@users.noreply.github.com"
git add .
if git status --porcelain | grep -q .; then
    git commit -m "docs(wiki): restore all 24 documentation pages, specs, diagrams, and full sidebar index"
    git push origin master
    echo "✅ Successfully published all documentation pages to https://github.com/Dmdv/async-worker-pool_zig/wiki"
else
    echo "Everything in Wiki is up-to-date."
fi
