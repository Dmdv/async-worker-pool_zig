const std = @import("std");
const awp = @import("awp");

const NUM_MSGS = 1_000_000;
const NUM_WORKERS = 32;
const QUEUE_CAP = 2048;

var g_done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_simd_acc: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

fn benchProcess(frame: *const awp.Frame) void {
    const sum = awp.fastSum64(frame.payload[0..64]);
    _ = g_simd_acc.fetchAdd(sum, .monotonic);
    _ = g_done.fetchAdd(1, .release);
}

pub fn main() !void {
    std.debug.print("\n=== Zig 0.16 Multi-Threaded Arena Pool & SIMD Dispatch Benchmark ===\n", .{});
    awp.pinToPerformanceCores();

    const backing_allocator = std.heap.page_allocator;

    // 1. Full Multi-Threaded Pool Benchmark (Arena Allocator Lifecycle)
    const Pool = awp.AwpPool(NUM_WORKERS, QUEUE_CAP);
    var pool = try Pool.init(backing_allocator, benchProcess);
    defer pool.deinit();

    g_done.store(0, .release);
    g_simd_acc.store(0, .release);

    const t0 = awp.nowNs();

    for (0..NUM_MSGS) |i| {
        const shard: u32 = @truncate(i % NUM_WORKERS);
        var claim = pool.claim(shard);
        while (claim == null) {
            std.atomic.spinLoopHint();
            claim = pool.claim(shard);
        }

        const c = claim.?;
        c.frame.payload_len = 64;
        for (0..64) |b| {
            c.frame.payload[b] = @truncate(i + b);
        }

        pool.commit(c);
    }

    while (g_done.load(.acquire) < NUM_MSGS) {
        std.atomic.spinLoopHint();
    }

    const t1 = awp.nowNs();
    const duration_ns = @as(f64, @floatFromInt(t1 - t0));
    const duration_sec = duration_ns / 1_000_000_000.0;
    const throughput = @as(f64, @floatFromInt(NUM_MSGS)) / duration_sec;
    const avg_lat = duration_ns / @as(f64, @floatFromInt(NUM_MSGS));

    std.debug.print("Messages: {d} | Workers: {d} | Queue Capacity: {d}\n", .{ NUM_MSGS, NUM_WORKERS, QUEUE_CAP });
    std.debug.print("Checksum Accumulator: {d}\n", .{g_simd_acc.load(.monotonic)});
    std.debug.print("Throughput: {d:.2} M msg/sec (Wall: {d:.2} ms)\n", .{ throughput / 1e6, duration_ns / 1e6 });
    std.debug.print("Average Latency (Claim -> Direct Write -> Commit -> SIMD): {d:.2} ns ({d:.2} µs)\n\n", .{ avg_lat, avg_lat / 1000.0 });
}
