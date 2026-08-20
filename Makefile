.PHONY: all check fmt lint bench check-rust bench-rust bench-baseline bench-compare clean

all: lint check check-rust

fmt:
	zig fmt src/*.zig bench/*.zig

lint:
	zig fmt --check src/*.zig bench/*.zig

check:
	zig test src/root.zig -lc

bench:
	zig build bench -Doptimize=ReleaseFast

bench-baseline:
	@mkdir -p benchmarks
	zig build bench -Doptimize=ReleaseFast -- --json benchmarks/baseline.json

bench-compare:
	@mkdir -p benchmarks
	zig build bench -Doptimize=ReleaseFast -- --json /tmp/awp_current_bench.json
	python3 scripts/bench_compare.py benchmarks/baseline.json /tmp/awp_current_bench.json

check-rust:
	cd bindings/rust && cargo test

bench-rust:
	cd bindings/rust && cargo run --release --example bench_throughput

clean:
	rm -rf .zig-cache zig-cache zig-out bindings/rust/target /tmp/awp_current_bench.json
