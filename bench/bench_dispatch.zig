const std = @import("std");
const awp = @import("awp");
const c_stdio = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const NUM_MSGS = 1_000_000;
const NUM_WORKERS = 4;
const QUEUE_CAP = 2048;
const MSGS_PER_WORKER = (NUM_MSGS / NUM_WORKERS) * 2;

const WorkerStat = struct {
    done: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
    simd_acc: u64 align(64) = 0,
    latencies: []u64 = undefined,
    count: usize = 0,
};

var g_stats: [NUM_WORKERS]WorkerStat = [_]WorkerStat{.{}} ** NUM_WORKERS;

fn benchProcess(frame: *const awp.Frame) void {
    const now = awp.nowNs();
    const sum = awp.fastSum64(frame.payload[0..64]);
    const shard = frame.shard % NUM_WORKERS;
    g_stats[shard].simd_acc +%= sum;
    if (g_stats[shard].count < MSGS_PER_WORKER and frame.submit_ns > 0 and now >= frame.submit_ns) {
        g_stats[shard].latencies[g_stats[shard].count] = now - frame.submit_ns;
        g_stats[shard].count += 1;
    }
    _ = g_stats[shard].done.fetchAdd(1, .release);
}

pub fn main() !void {
    std.debug.print("\n=== Zig 0.16 Multi-Threaded Arena Pool & SIMD Dispatch Benchmark ===\n", .{});
    awp.pinToPerformanceCores();

    const backing_allocator = std.heap.page_allocator;

    for (&g_stats) |*s| {
        s.latencies = try backing_allocator.alloc(u64, MSGS_PER_WORKER);
        s.count = 0;
        s.simd_acc = 0;
        s.done.store(0, .release);
    }

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

    var total_checksum: u64 = 0;
    var total_lat_samples: usize = 0;
    for (g_stats) |stat| {
        total_checksum +%= stat.simd_acc;
        total_lat_samples += stat.count;
    }

    const all_lat = try backing_allocator.alloc(u64, total_lat_samples);
    defer backing_allocator.free(all_lat);

    var offset: usize = 0;
    var sum_lat: f64 = 0;
    for (g_stats) |stat| {
        @memcpy(all_lat[offset .. offset + stat.count], stat.latencies[0..stat.count]);
        offset += stat.count;
    }

    for (all_lat) |lat| {
        sum_lat += @as(f64, @floatFromInt(lat));
    }

    std.mem.sort(u64, all_lat, {}, std.sort.asc(u64));

    const mean_lat = if (all_lat.len > 0) sum_lat / @as(f64, @floatFromInt(all_lat.len)) else 0;
    const min_lat = if (all_lat.len > 0) all_lat[0] else 0;
    const p50_lat = if (all_lat.len > 0) all_lat[@as(usize, @intFromFloat(@as(f64, @floatFromInt(all_lat.len)) * 0.50))] else 0;
    const p90_lat = if (all_lat.len > 0) all_lat[@as(usize, @intFromFloat(@as(f64, @floatFromInt(all_lat.len)) * 0.90))] else 0;
    const p99_lat = if (all_lat.len > 0) all_lat[@as(usize, @intFromFloat(@as(f64, @floatFromInt(all_lat.len)) * 0.99))] else 0;
    const p999_lat = if (all_lat.len > 0) all_lat[@as(usize, @intFromFloat(@as(f64, @floatFromInt(all_lat.len)) * 0.999))] else 0;
    const p9999_lat = if (all_lat.len > 0) all_lat[@as(usize, @intFromFloat(@as(f64, @floatFromInt(all_lat.len)) * 0.9999))] else 0;
    const max_lat = if (all_lat.len > 0) all_lat[all_lat.len - 1] else 0;

    std.debug.print("Messages: {d} | Workers: {d} | Queue Capacity: {d}\n", .{ NUM_MSGS, NUM_WORKERS, QUEUE_CAP });
    std.debug.print("Checksum Accumulator: {d}\n", .{total_checksum});
    std.debug.print("Throughput: {d:.2} M msg/sec (Wall: {d:.2} ms)\n", .{ throughput / 1e6, duration_ns / 1e6 });
    std.debug.print("Latency Percentiles (Submit -> Direct Write -> Commit -> SIMD):\n", .{});
    std.debug.print("  Min   : {d:6} ns ({d:6.3} µs)\n", .{ min_lat, @as(f64, @floatFromInt(min_lat)) / 1000.0 });
    std.debug.print("  Mean  : {d:6.1} ns ({d:6.3} µs)\n", .{ mean_lat, mean_lat / 1000.0 });
    std.debug.print("  p50   : {d:6} ns ({d:6.3} µs)\n", .{ p50_lat, @as(f64, @floatFromInt(p50_lat)) / 1000.0 });
    std.debug.print("  p90   : {d:6} ns ({d:6.3} µs)\n", .{ p90_lat, @as(f64, @floatFromInt(p90_lat)) / 1000.0 });
    std.debug.print("  p99   : {d:6} ns ({d:6.3} µs)\n", .{ p99_lat, @as(f64, @floatFromInt(p99_lat)) / 1000.0 });
    std.debug.print("  p99.9 : {d:6} ns ({d:6.3} µs)\n", .{ p999_lat, @as(f64, @floatFromInt(p999_lat)) / 1000.0 });
    std.debug.print("  p99.99: {d:6} ns ({d:6.3} µs)\n", .{ p9999_lat, @as(f64, @floatFromInt(p9999_lat)) / 1000.0 });
    std.debug.print("  Max   : {d:6} ns ({d:6.3} µs)\n\n", .{ max_lat, @as(f64, @floatFromInt(max_lat)) / 1000.0 });

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

    // 3. Concurrent Ultra-Fast SPSC Ring (4KB Frame)
    std.debug.print("=== Zig 0.16 Concurrent Ultra-Fast SPSC Ring (4KB Frame, 0 CAS) ===\n", .{});
    const FrameSpsc = awp.FrameSpscRing(QUEUE_CAP);
    var spsc = try FrameSpsc.init(backing_allocator);
    defer spsc.deinit();

    const SpscContext = struct {
        ring: *FrameSpsc,
        n: usize,
        ready: std.atomic.Value(bool),
        done: std.atomic.Value(bool),
        csum: std.atomic.Value(u64),

        fn consumerThread(ctx: *@This()) void {
            awp.pinToPerformanceCores();
            ctx.ready.store(true, .release);
            var got: usize = 0;
            var sum: u64 = 0;
            while (got < ctx.n) {
                if (ctx.ring.peek()) |frame| {
                    sum +%= awp.fastSum64(frame.payload[0..64]);
                    ctx.ring.consume();
                    got += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            ctx.csum.store(sum, .release);
            ctx.done.store(true, .release);
        }
    };

    var spsc_ctx = SpscContext{
        .ring = &spsc,
        .n = NUM_MSGS,
        .ready = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
        .csum = std.atomic.Value(u64).init(0),
    };

    const cons_thread = try std.Thread.spawn(.{}, SpscContext.consumerThread, .{&spsc_ctx});
    while (!spsc_ctx.ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const s_t0 = awp.nowNs();

    for (0..NUM_MSGS) |_| {
        while (!spsc.tryPush(&raw_frame)) {
            std.atomic.spinLoopHint();
        }
    }

    cons_thread.join();
    const s_t1 = awp.nowNs();
    const s_duration_ns = @as(f64, @floatFromInt(s_t1 - s_t0));
    const s_duration_sec = s_duration_ns / 1_000_000_000.0;
    const s_throughput = @as(f64, @floatFromInt(NUM_MSGS)) / s_duration_sec;
    const s_avg_lat = s_duration_ns / @as(f64, @floatFromInt(NUM_MSGS));

    std.debug.print("Concurrent 4KB SPSC Throughput: {d:.2} M ops/sec (Wall: {d:.2} ms)\n", .{ s_throughput / 1e6, s_duration_ns / 1e6 });
    std.debug.print("Concurrent 4KB SPSC Hop Period: {d:.2} ns ({d:.4} µs) | Checksum: {d}\n\n", .{ s_avg_lat, s_avg_lat / 1000.0, spsc_ctx.csum.load(.monotonic) });

    // 4. Raw Pointer Passing SPSC Ring (Exact Equivalent to C bench_ring.c SPSC)
    std.debug.print("=== Zig 0.16 Pure Pointer SPSC Ring (Exact Equivalent to C bench_ring.c) ===\n", .{});
    const PtrSpsc = awp.SpscRing(usize, QUEUE_CAP);
    var ptr_ring = try PtrSpsc.init(backing_allocator);
    defer ptr_ring.deinit();

    const PtrCtx = struct {
        ring: *PtrSpsc,
        n: usize,
        ready: std.atomic.Value(bool),
        done: std.atomic.Value(bool),

        fn runConsumer(ctx: *@This()) void {
            awp.pinToPerformanceCores();
            ctx.ready.store(true, .release);
            var got: usize = 0;
            while (got < ctx.n) {
                if (ctx.ring.popValue()) |_| {
                    got += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            ctx.done.store(true, .release);
        }
    };

    const PTR_MSGS = 5_000_000;
    var ptr_ctx = PtrCtx{
        .ring = &ptr_ring,
        .n = PTR_MSGS,
        .ready = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
    };

    const ptr_cons_thread = try std.Thread.spawn(.{}, PtrCtx.runConsumer, .{&ptr_ctx});
    while (!ptr_ctx.ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const p_t0 = awp.nowNs();

    for (0..PTR_MSGS) |i| {
        while (!ptr_ring.pushValue(i)) {
            std.atomic.spinLoopHint();
        }
    }

    ptr_cons_thread.join();
    const p_t1 = awp.nowNs();
    const p_duration_ns = @as(f64, @floatFromInt(p_t1 - p_t0));
    const p_duration_sec = p_duration_ns / 1_000_000_000.0;
    const p_throughput = @as(f64, @floatFromInt(PTR_MSGS)) / p_duration_sec;
    const p_avg_lat = p_duration_ns / @as(f64, @floatFromInt(PTR_MSGS));

    std.debug.print("Pure SPSC Ring Throughput: {d:.2} M ops/sec (Wall: {d:.2} ms)\n", .{ p_throughput / 1e6, p_duration_ns / 1e6 });
    std.debug.print("Pure SPSC Ring Hop Period: {d:.2} ns ({d:.4} µs)\n\n", .{ p_avg_lat, p_avg_lat / 1000.0 });

    // 5. Phase 2: Generic 64-Byte Cacheline POD SPSC Ring (BookUpdate64)
    std.debug.print("=== Zig 0.16 Generic 64-Byte Cacheline POD Ring (BookUpdate64) ===\n", .{});
    const PodSpsc = awp.Spsc64Ring(awp.BookUpdate64, QUEUE_CAP);
    var pod_ring = try PodSpsc.init(backing_allocator);
    defer pod_ring.deinit();

    const POD_MSGS = 5_000_000;
    const PodCtx = struct {
        ring: *PodSpsc,
        n: usize,
        ready: std.atomic.Value(bool),
        done: std.atomic.Value(bool),
        csum: std.atomic.Value(u64),

        fn runConsumer(ctx: *@This()) void {
            awp.pinToPerformanceCores();
            ctx.ready.store(true, .release);
            var got: usize = 0;
            var sum: u64 = 0;
            while (got < ctx.n) {
                if (ctx.ring.popValue()) |item| {
                    sum +%= item.seq +% @as(u64, @bitCast(item.bid_price));
                    got += 1;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            ctx.csum.store(sum, .release);
            ctx.done.store(true, .release);
        }
    };

    var pod_ctx = PodCtx{
        .ring = &pod_ring,
        .n = POD_MSGS,
        .ready = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
        .csum = std.atomic.Value(u64).init(0),
    };

    const pod_sample = awp.BookUpdate64{
        .timestamp_ns = 1_000_000,
        .seq = 1,
        .symbol_id = 100,
        .flags = 2,
        .bid_price = 50000.25,
        .bid_qty = 1.5,
        .ask_price = 50000.50,
        .ask_qty = 3.0,
    };

    const pod_cons_thread = try std.Thread.spawn(.{}, PodCtx.runConsumer, .{&pod_ctx});
    while (!pod_ctx.ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const pod_t0 = awp.nowNs();

    for (0..POD_MSGS) |_| {
        while (!pod_ring.tryPush(&pod_sample)) {
            std.atomic.spinLoopHint();
        }
    }

    pod_cons_thread.join();
    const pod_t1 = awp.nowNs();
    const pod_duration_ns = @as(f64, @floatFromInt(pod_t1 - pod_t0));
    const pod_duration_sec = pod_duration_ns / 1_000_000_000.0;
    const pod_throughput = @as(f64, @floatFromInt(POD_MSGS)) / pod_duration_sec;
    const pod_avg_lat = pod_duration_ns / @as(f64, @floatFromInt(POD_MSGS));

    std.debug.print("64-Byte POD SPSC Ring Throughput: {d:.2} M ops/sec (Wall: {d:.2} ms)\n", .{ pod_throughput / 1e6, pod_duration_ns / 1e6 });
    std.debug.print("64-Byte POD SPSC Mean Latency: {d:.2} ns ({d:.4} µs) | Checksum: {d}\n\n", .{ pod_avg_lat, pod_avg_lat / 1000.0, pod_ctx.csum.load(.monotonic) });

    // 6. Variable-Length Zero-Copy BipBuffer Streaming Benchmark
    std.debug.print("=== Zig 0.16 Variable-Length Zero-Copy BipBuffer (Bipartite Ring) ===\n", .{});
    const BIP_CAP = 256 * 1024; // 256KB BipBuffer
    const DESC_CAP = 8192;
    const BIP_MSGS = 2_000_000;
    const RingType = awp.BipRing(BIP_CAP, DESC_CAP);
    var bip_ring = try RingType.init(backing_allocator);
    defer bip_ring.deinit();

    const BipCtx = struct {
        ring: *RingType,
        n: usize,
        ready: std.atomic.Value(bool),
        done: std.atomic.Value(bool),
        csum: std.atomic.Value(u64),
        total_lat_ns: std.atomic.Value(u64),

        fn runConsumer(ctx: *@This()) void {
            awp.pinToPerformanceCores();
            ctx.ready.store(true, .release);
            var got: usize = 0;
            var sum: u64 = 0;
            var total_lat: u64 = 0;
            while (got < ctx.n) {
                if (ctx.ring.popPacket()) |pkt| {
                    const now = awp.nowNs();
                    if (now >= pkt.desc.timestamp_ns) {
                        total_lat +%= (now - pkt.desc.timestamp_ns);
                    }
                    sum +%= pkt.payload[0] +% pkt.payload[pkt.payload.len - 1] +% pkt.desc.timestamp_ns;
                    got += 1;
                    ctx.ring.releasePacket(pkt.desc);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            ctx.total_lat_ns.store(total_lat, .release);
            ctx.csum.store(sum, .release);
            ctx.done.store(true, .release);
        }
    };

    var bip_ctx = BipCtx{
        .ring = &bip_ring,
        .n = BIP_MSGS,
        .ready = std.atomic.Value(bool).init(false),
        .done = std.atomic.Value(bool).init(false),
        .csum = std.atomic.Value(u64).init(0),
        .total_lat_ns = std.atomic.Value(u64).init(0),
    };

    const bip_cons_thread = try std.Thread.spawn(.{}, BipCtx.runConsumer, .{&bip_ctx});
    while (!bip_ctx.ready.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    const bip_t0 = awp.nowNs();

    var payload_buf: [1500]u8 = undefined;
    @memset(&payload_buf, 0x55);
    const msg_sizes = [_]usize{ 64, 128, 256, 512, 1024, 1400 };

    for (0..BIP_MSGS) |i| {
        const sz = msg_sizes[i % msg_sizes.len];
        payload_buf[0] = @truncate(i);
        payload_buf[sz - 1] = @truncate(i >> 8);

        while (!bip_ring.pushPacket(payload_buf[0..sz], awp.nowNs())) {
            std.atomic.spinLoopHint();
        }
    }

    bip_cons_thread.join();
    const bip_t1 = awp.nowNs();
    const bip_duration_ns = @as(f64, @floatFromInt(bip_t1 - bip_t0));
    const bip_duration_sec = bip_duration_ns / 1_000_000_000.0;
    const bip_throughput = @as(f64, @floatFromInt(BIP_MSGS)) / bip_duration_sec;
    const bip_service_time = bip_duration_ns / @as(f64, @floatFromInt(BIP_MSGS));
    const bip_avg_lat = @as(f64, @floatFromInt(bip_ctx.total_lat_ns.load(.monotonic))) / @as(f64, @floatFromInt(BIP_MSGS));

    std.debug.print("Variable-Length BipRing Throughput: {d:.2} M pkts/sec (Service Time: {d:.2} ns/pkt)\n", .{ bip_throughput / 1e6, bip_service_time });
    std.debug.print("Variable-Length BipRing Mean Latency: {d:.2} ns ({d:.4} µs) | Checksum: {d}\n\n", .{ bip_avg_lat, bip_avg_lat / 1000.0, bip_ctx.csum.load(.monotonic) });

    // -------------------------------------------------------------------------------------
    // Section 7: Phase 4 Hybrid Fast-Path Trading Reactor & Concurrent Off-Path Pipeline
    // -------------------------------------------------------------------------------------
    std.debug.print("=== Zig 0.16 Hybrid Fast-Path Trading Reactor & Off-Path Pipeline ===\n", .{});
    const REACTOR_TICKS = 2_000_000;

    var offpath = try awp.OffPathPipeline.init(backing_allocator);
    defer offpath.deinit();
    try offpath.start();

    var reactor = awp.TradingReactor(awp.OffPathPipeline.QUEUE_CAP).init();
    reactor.bindRiskRing(&offpath.risk_ring);
    reactor.bindAuditRing(&offpath.audit_ring);
    reactor.bindTelemetryRing(&offpath.telemetry_ring);

    var dummy_update = awp.BookUpdate64{
        .timestamp_ns = 0,
        .seq = 0,
        .symbol_id = 1,
        .flags = 0x01,
        .bid_price = 65000.0,
        .bid_qty = 1.5,
        .ask_price = 65000.5,
        .ask_qty = 2.0,
    };

    const reactor_t0 = awp.nowNs();
    for (0..REACTOR_TICKS) |i| {
        dummy_update.timestamp_ns = awp.nowNs();
        dummy_update.seq = i + 1;
        dummy_update.bid_price = 65000.0 + @as(f64, @floatFromInt(i % 100)) * 0.1;
        dummy_update.ask_price = dummy_update.bid_price + 0.5;

        _ = reactor.processTick(dummy_update);
    }
    const reactor_t1 = awp.nowNs();

    const reactor_duration_ns = @as(f64, @floatFromInt(reactor_t1 - reactor_t0));
    const reactor_duration_sec = reactor_duration_ns / 1_000_000_000.0;
    const reactor_throughput = @as(f64, @floatFromInt(REACTOR_TICKS)) / reactor_duration_sec;
    const reactor_mean_lat = reactor_duration_ns / @as(f64, @floatFromInt(REACTOR_TICKS));

    var wait_attempts: usize = 0;
    while ((!offpath.risk_ring.isEmpty() or !offpath.audit_ring.isEmpty() or !offpath.telemetry_ring.isEmpty()) and wait_attempts < 1000) : (wait_attempts += 1) {
        awp.sleepNs(100_000);
    }

    std.debug.print("Trading Reactor Fast-Path Throughput: {d:.2} M ticks/sec (Tick-to-Trade: {d:.2} ns)\n", .{
        reactor_throughput / 1e6,
        reactor_mean_lat,
    });
    std.debug.print("Off-Path Workers Processed: Risk={d} | Audit={d} | Telemetry={d} | Overruns={d}\n\n", .{
        offpath.risk_processed.load(.monotonic),
        offpath.audit_processed.load(.monotonic),
        offpath.telemetry_processed.load(.monotonic),
        reactor.getOverrunCount(),
    });

    var json_path: ?[]const u8 = null;
    const env_val = c_stdio.getenv("BENCH_JSON_OUT");
    if (env_val != null) {
        json_path = std.mem.span(env_val);
    }

    if (json_path) |path| {
        var buf: [2048]u8 = undefined;
        const json_content = try std.fmt.bufPrint(&buf,
            \\{{
            \\  "engine": "zig-0.16",
            \\  "num_messages": {d},
            \\  "num_workers": {d},
            \\  "pool_throughput_mps": {d:.2},
            \\  "pool_wall_ms": {d:.2},
            \\  "pool_mean_ns": {d:.2},
            \\  "pool_min_ns": {d},
            \\  "pool_p50_ns": {d},
            \\  "pool_p90_ns": {d},
            \\  "pool_p99_ns": {d},
            \\  "pool_p999_ns": {d},
            \\  "pool_p9999_ns": {d},
            \\  "pool_max_ns": {d},
            \\  "spsc_throughput_mops": {d:.2},
            \\  "spsc_mean_ns": {d:.2},
            \\  "spsc64_throughput_mops": {d:.2},
            \\  "spsc64_mean_ns": {d:.2},
            \\  "bip_throughput_mops": {d:.2},
            \\  "bip_mean_ns": {d:.2},
            \\  "reactor_throughput_mps": {d:.2},
            \\  "reactor_mean_ns": {d:.2}
            \\}}
            \\
        , .{
            NUM_MSGS,
            NUM_WORKERS,
            throughput / 1e6,
            duration_ns / 1e6,
            mean_lat,
            min_lat,
            p50_lat,
            p90_lat,
            p99_lat,
            p999_lat,
            p9999_lat,
            max_lat,
            p_throughput / 1e6,
            p_avg_lat,
            pod_throughput / 1e6,
            pod_avg_lat,
            bip_throughput / 1e6,
            bip_avg_lat,
            reactor_throughput / 1e6,
            reactor_mean_lat,
        });
        var path_z: [1024:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const f = c_stdio.fopen(&path_z, "wb");
        if (f != null) {
            _ = c_stdio.fwrite(json_content.ptr, 1, json_content.len, f);
            _ = c_stdio.fclose(f);
            std.debug.print("✓ Saved benchmark JSON metrics to: {s}\n\n", .{path});
        }
    }
}
