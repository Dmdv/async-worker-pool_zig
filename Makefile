.PHONY: all check fmt lint bench check-rust bench-rust clean

all: lint check check-rust

fmt:
	zig fmt src/*.zig bench/*.zig

lint:
	zig fmt --check src/*.zig bench/*.zig

check:
	zig test src/root.zig -lc

bench:
	zig build bench -Doptimize=ReleaseFast

check-rust:
	cd bindings/rust && cargo test

bench-rust:
	cd bindings/rust && cargo run --release --example bench_throughput

clean:
	rm -rf .zig-cache zig-cache zig-out bindings/rust/target
