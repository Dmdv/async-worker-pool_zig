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
### 📖 Table of Contents

* [🏠 Home](Home)
* [🚀 Getting Started](Getting-Started)

#### 🏛 Architecture
* [System Architecture](System-Architecture)
* [Zero-Copy Memory Models](Zero-Copy-Memory-Models)
* [Hardware Hardening & HugePages](Hardware-Hardening-and-HugePages)

#### ⚡ Concurrency Primitives
* [SPSC Ring Buffers (8B & 64B POD)](SPSC-Ring-Buffers)
* [Bipartite Buffers & BipRing](Bipartite-Buffers-and-BipRing)
* [Multi-Threaded Worker Pool & SIMD](Multi-Threaded-Worker-Pool)

#### 🔌 Language Interop
* [C ABI Specification](C-ABI-Specification)
* [Rust FFI & Safe RAII Bindings](Rust-FFI-Bindings)

#### 📊 Benchmarks & Roadmap
* [HFT Benchmark Methodology](HFT-Benchmark-Methodology)
* [Evolution Roadmap](HFT-Evolution-Roadmap)
EOF

# 2. Copy documentation pages
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

# 3. Transform relative markdown links to Wiki links
python3 - << 'PY'
import os
import re

wiki_dir = "/tmp/awp_wiki"
replacements = {
    r'getting-started/quickstart\.md': 'Getting-Started',
    r'architecture/overview\.md': 'System-Architecture',
    r'architecture/memory-models\.md': 'Zero-Copy-Memory-Models',
    r'primitives/hugepages-slab\.md': 'Hardware-Hardening-and-HugePages',
    r'primitives/spsc-ring\.md': 'SPSC-Ring-Buffers',
    r'primitives/bip-buffer\.md': 'Bipartite-Buffers-and-BipRing',
    r'primitives/worker-pool\.md': 'Multi-Threaded-Worker-Pool',
    r'ffi/c-abi\.md': 'C-ABI-Specification',
    r'ffi/rust-bindings\.md': 'Rust-FFI-Bindings',
    r'benchmarks/benchmark-suite\.md': 'HFT-Benchmark-Methodology',
    r'docs/HFT_EVOLUTION_ROADMAP\.md': 'HFT-Evolution-Roadmap',
    r'HFT_EVOLUTION_ROADMAP\.md': 'HFT-Evolution-Roadmap',
    r'README\.md': 'Home',
}

for root, _, files in os.walk(wiki_dir):
    for f in files:
        if f.endswith(".md"):
            p = os.path.join(root, f)
            with open(p, "r", encoding="utf-8") as file:
                content = file.read()
            for pattern, target in replacements.items():
                content = re.sub(pattern, target, content)
            with open(p, "w", encoding="utf-8") as file:
                file.write(content)
PY

# 4. Commit and Push to Wiki repository
git config user.name "Dmdv"
git config user.email "805238+Dmdv@users.noreply.github.com"
git add .
git commit -m "docs(wiki): fix native wiki navigation links and sidebar" || true
git push origin master

echo "✅ Successfully published documentation to https://github.com/Dmdv/async-worker-pool_zig/wiki"
