#!/usr/bin/env bash
set -euo pipefail

WIKI_DIR="/tmp/awp_wiki"
DOCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs"

echo "=== Preparing GitHub Wiki for async-worker-pool_zig ==="

# Switch GitHub identity to Dmdv
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
### Navigation
* [[Home]]
* [[Getting Started|Getting-Started]]

### Core Architecture
* [[System Architecture|System-Architecture]]
* [[Zero-Copy Memory Models|Zero-Copy-Memory-Models]]
* [[Hardware Hardening & HugePages|Hardware-Hardening-and-HugePages]]

### Concurrency Primitives
* [[SPSC Ring Buffers (8B & 64B POD)|SPSC-Ring-Buffers]]
* [[Bipartite Buffers & BipRing|Bipartite-Buffers-and-BipRing]]
* [[Multi-Threaded Worker Pool & SIMD|Multi-Threaded-Worker-Pool]]

### Language Interoperability
* [[C ABI Specification|C-ABI-Specification]]
* [[Rust FFI & Safe RAII Bindings|Rust-FFI-Bindings]]

### Benchmarks & Performance
* [[HFT Benchmark Methodology|HFT-Benchmark-Methodology]]
* [[Evolution Roadmap|HFT-Evolution-Roadmap]]
EOF

# 2. Copy and map documentation pages
cp "$DOCS_DIR/README.md" "$WIKI_DIR/Home.md"
cp "$DOCS_DIR/getting-started/quickstart.md" "$WIKI_DIR/Getting-Started.md"
cp "$DOCS_DIR/architecture/overview.md" "$WIKI_DIR/System-Architecture.md"
cp "$DOCS_DIR/architecture/memory-models.md" "$WIKI_DIR/Zero-Copy-Memory-Models.md"
cp "$DOCS_DIR/primitives/hugepages-slab.md" "$WIKI_DIR/Hardware-Hardening-and-HugePages.md"
cp "$DOCS_DIR/primitives/spsc-ring.md" "$WIKI_DIR/SPSC-Ring-Buffers.md"
cp "$DOCS_DIR/primitives/bip-buffer.md" "$WIKI_DIR/Bipartite-Buffers-and-BipRing.md"
cp "$DOCS_DIR/primitives/worker-pool.md" "$WIKI_DIR/Multi-Threaded-Worker-Pool.md"
cp "$DOCS_DIR/ffi/c-abi.md" "$WIKI_DIR/C-ABI-Specification.md"
cp "$DOCS_DIR/ffi/rust-bindings.md" "$WIKI_DIR/Rust-FFI-Bindings.md"
cp "$DOCS_DIR/benchmarks/benchmark-suite.md" "$WIKI_DIR/HFT-Benchmark-Methodology.md"
cp "$DOCS_DIR/HFT_EVOLUTION_ROADMAP.md" "$WIKI_DIR/HFT-Evolution-Roadmap.md"

# 3. Commit and Push to Wiki repository
git config user.name "Dmdv"
git config user.email "805238+Dmdv@users.noreply.github.com"
git add .
git commit -m "docs(wiki): sync full documentation suite and sidebar" || true
git push origin master

echo "✅ Successfully published documentation to https://github.com/Dmdv/async-worker-pool_zig/wiki"
