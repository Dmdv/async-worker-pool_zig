const std = @import("std");
const awp = @import("awp");

const NUM_MSGS = 1_000_000;
const NUM_WORKERS = 32;
const QUEUE_CAP = 2048;

const WorkerStat = struct {
    done: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
    simd_acc: u64 align(64) = 0,
};

var g_stats: [NUM_WORKERS]WorkerStat = [_]WorkerStat{.{}} ** NUM_WORKERS;

fn benchProcess(frame: *const awp.Frame) void {
    const sum = awp.fastSum64(frame.payload[0..64]);
    const shard = frame.shard % NUM_WORKERS;
    g_stats[shard].simd_acc +%= sum;
    _ = g_stats[shard].done.fetchAdd(1, .release);
}

pub fn main() !void {
    std.debug.print("\n=== Zig 0.16 Multi-Threaded Arena Pool & SIMD Dispatch Benchmark ===\n", .{});
    awp.pinToPerformanceCores();

    const backing_allocator = std.heap.page_allocator;

    // 1. Full Multi-Threaded Pool Benchmark (Arena Allocator Lifecycle)
    const Pool = awp.AwpPool(NUM_WORKERS, QUEUE_CAP);
    var pool = try Pool.init(backing_allocator, benchProcess);
    defer pool.deinit();

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

    while (true) {
        var total_done: usize = 0;
        for (&g_stats) |*stat| {
            total_done += stat.done.load(.acquire);
        }
        if (total_done >= NUM_MSGS) break;
        std.atomic.spinLoopHint();
    }

    const t1 = awp.nowNs();
    const duration_ns = @as(f64, @floatFromInt(t1 - t0));
    const duration_sec = duration_ns / 1_000_000_000.0;
    const throughput = @as(f64, @floatFromInt(NUM_MSGS)) / duration_sec;
    const avg_lat = duration_ns / @as(f64, @floatFromInt(NUM_MSGS));

    var total_checksum: u64 = 0;
    for (g_stats) |stat| {
        total_checksum +%= stat.simd_acc;
    }

    std.debug.print("Messages: {d} | Workers: {d} | Queue Capacity: {d}\n", .{ NUM_MSGS, NUM_WORKERS, QUEUE_CAP });
    std.debug.print("Checksum Accumulator: {d}\n", .{total_checksum});
    std.debug.print("Throughput: {d:.2} M msg/sec (Wall: {d:.2} ms)\n", .{ throughput / 1e6, duration_ns / 1e6 });
    std.debug.print("Average Latency (Claim -> Direct Write -> Commit -> SIMD): {d:.2} ns ({d:.2} µs)\n\n", .{ avg_lat, avg_lat / 1000.0 });

    // 2. Raw Single-Ring Zero-Allocation Stream Benchmark
    std.debug.print("=== Zig 0.16 Raw Single-Ring Lock-Free + SIMD Stream Benchmark ===\n", .{});
    const Ring = awp.LockFreeRing(QUEUE_CAP);
    var ring = try Ring.init(backing_allocator);
    defer ring.deinit();

    var raw_frame = awp.Frame{};
    raw_frame.payload_len = 64;
    for (0..64) |b| {
        raw_frame.payload[b] = @truncate(b);
    }

    const r_t0 = awp.nowNs();
    var r_sum: u64 = 0;

    for (0..NUM_MSGS) |_| {
        while (!ring.tryPush(&raw_frame)) {
            std.atomic.spinLoopHint();
        }
        const popped = ring.tryPop().?;
        r_sum +%= awp.fastSum64(popped.payload[0..64]);
    }

    const r_t1 = awp.nowNs();
    const r_duration_ns = @as(f64, @floatFromInt(r_t1 - r_t0));
    const r_duration_sec = r_duration_ns / 1_000_000_000.0;
    const r_throughput = @as(f64, @floatFromInt(NUM_MSGS)) / r_duration_sec;
    const r_avg_lat = r_duration_ns / @as(f64, @floatFromInt(NUM_MSGS));

    std.debug.print("Raw Ring Throughput: {d:.2} M ops/sec (Wall: {d:.2} ms)\n", .{ r_throughput / 1e6, r_duration_ns / 1e6 });
    std.debug.print("Raw Ring Mean Hop Latency: {d:.2} ns ({d:.4} µs) | Checksum: {d}\n\n", .{ r_avg_lat, r_avg_lat / 1000.0, r_sum });
}
