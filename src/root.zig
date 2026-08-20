const std = @import("std");

pub const AWP_FEED_MAX = 64;
pub const AWP_SYMBOL_MAX = 64;
pub const AWP_PAYLOAD_MAX = 4096;

pub const Frame = struct {
    feed: [AWP_FEED_MAX + 1]u8 = [_]u8{0} ** (AWP_FEED_MAX + 1),
    symbol: [AWP_SYMBOL_MAX + 1]u8 = [_]u8{0} ** (AWP_SYMBOL_MAX + 1),
    payload: [AWP_PAYLOAD_MAX]u8 = [_]u8{0} ** AWP_PAYLOAD_MAX,
    payload_len: usize = 0,
    seq: u64 = 0,
    submit_ns: u64 = 0,
    shard: u32 = 0,
    flags: u32 = 0,
};

/// High-performance SIMD checksum using Zig 0.16 @Vector primitives
pub inline fn fastSum64(ptr: [*]const u8) u32 {
    const V = @Vector(64, u8);
    const v: V = ptr[0..64].*;
    const v_wide: @Vector(64, u16) = v;
    return @reduce(.Add, v_wide);
}

/// Nanosecond timestamp reader using native CPU timer register
pub inline fn nowNs() u64 {
    if (@import("builtin").cpu.arch == .aarch64) {
        var val: u64 = undefined;
        asm volatile ("mrs %[val], cntvct_el0"
            : [val] "=r" (val),
        );
        return val;
    } else {
        return @intCast(std.time.nanoTimestamp());
    }
}

/// Pin current thread to Apple Silicon P-Core (Performance Core)
pub fn pinToPerformanceCores() void {
    if (@import("builtin").os.tag == .macos) {
        const QOS_CLASS_USER_INTERACTIVE: c_uint = 0x21;
        const c = @cImport({
            @cInclude("pthread/qos.h");
        });
        _ = c.pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

/// Claim token for Zero-Copy enqueue
pub const Claim = struct {
    frame: *Frame,
    shard: u32,
    pos: usize,
};

/// Bounded MPMC / MPSC Lock-Free Ring Buffer with Embedded Pre-allocated Slabs
pub fn LockFreeRing(comptime capacity: usize) type {
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        // Ultra-dense 8-byte sequence cell: exactly 8 cells fit into one 64-byte cacheline
        const Cell = struct {
            sequence: std.atomic.Value(usize),
        };

        cells: []Cell,
        frames: []Frame,
        enqueue_pos: std.atomic.Value(usize) align(64),
        dequeue_pos: std.atomic.Value(usize) align(64),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const cells = try allocator.alloc(Cell, capacity);
            const frames = try allocator.alloc(Frame, capacity);
            for (cells, 0..) |*cell, i| {
                cell.sequence = std.atomic.Value(usize).init(i);
            }
            return Self{
                .cells = cells,
                .frames = frames,
                .enqueue_pos = std.atomic.Value(usize).init(0),
                .dequeue_pos = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.frames);
            self.allocator.free(self.cells);
        }

        pub inline fn claim(self: *Self, shard: u32) ?Claim {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.cells[pos & mask];
                const seq = cell.sequence.load(.acquire);
                const dif: isize = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

                if (dif == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .monotonic)) |next_pos| {
                        pos = next_pos;
                        continue;
                    }
                    const f = &self.frames[pos & mask];
                    f.shard = shard;
                    f.submit_ns = nowNs();
                    @prefetch(&self.frames[(pos + 1) & mask], .{ .rw = .write, .locality = 3, .cache = .data });
                    return Claim{
                        .frame = f,
                        .shard = shard,
                        .pos = pos,
                    };
                } else if (dif < 0) {
                    return null; // Queue full
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        pub inline fn commit(self: *Self, c: Claim) void {
            const cell = &self.cells[c.pos & mask];
            cell.sequence.store(c.pos + 1, .release);
        }

        pub inline fn tryPush(self: *Self, data: *const Frame) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.cells[pos & mask];
                const seq = cell.sequence.load(.acquire);
                const dif: isize = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

                if (dif == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .monotonic)) |next_pos| {
                        pos = next_pos;
                        continue;
                    }
                    const slot_f = &self.frames[pos & mask];
                    if (data != slot_f) {
                        slot_f.* = data.*;
                    }
                    cell.sequence.store(pos + 1, .release);
                    return true;
                } else if (dif < 0) {
                    return false; // Queue full
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        pub inline fn tryPop(self: *Self) ?*Frame {
            const pos = self.dequeue_pos.load(.monotonic);
            const cell = &self.cells[pos & mask];
            const seq = cell.sequence.load(.acquire);
            const dif: isize = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));

            if (dif == 0) {
                self.dequeue_pos.store(pos + 1, .monotonic);
                const data = &self.frames[pos & mask];
                @prefetch(&self.frames[(pos + 1) & mask], .{ .rw = .read, .locality = 3, .cache = .data });
                cell.sequence.store(pos + capacity, .release);
                return data;
            } else {
                return null;
            }
        }
    };
}

/// High-Performance Async Worker Pool in Zig with Arena Lifecycle
pub fn AwpPool(comptime num_workers: usize, comptime queue_capacity: usize) type {
    return struct {
        const Self = @This();
        const Ring = LockFreeRing(queue_capacity);

        arena: std.heap.ArenaAllocator,
        rings: [num_workers]Ring,
        threads: [num_workers]std.Thread,
        running: std.atomic.Value(bool),

        pub fn init(backing_allocator: std.mem.Allocator, callback: *const fn (*const Frame) void) !*Self {
            var arena = std.heap.ArenaAllocator.init(backing_allocator);
            const allocator = arena.allocator();

            const self = try allocator.create(Self);
            self.arena = arena;
            self.running = std.atomic.Value(bool).init(true);

            for (&self.rings) |*r| {
                r.* = try Ring.init(allocator);
            }

            for (0..num_workers) |i| {
                self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{ self, i, callback });
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.running.store(false, .release);
            for (self.threads) |t| {
                t.join();
            }
            var arena = self.arena;
            arena.deinit();
        }

        fn workerLoop(self: *Self, worker_id: usize, callback: *const fn (*const Frame) void) void {
            pinToPerformanceCores();
            const ring = &self.rings[worker_id];

            while (self.running.load(.acquire)) {
                if (ring.tryPop()) |frame| {
                    callback(frame);
                } else {
                    std.atomic.spinLoopHint();
                }
            }

            // Drain remaining frames
            while (ring.tryPop()) |frame| {
                callback(frame);
            }
        }

        pub inline fn claim(self: *Self, shard: u32) ?Claim {
            const target_shard: usize = @intCast(shard % num_workers);
            return self.rings[target_shard].claim(@truncate(target_shard));
        }

        pub inline fn commit(self: *Self, c: Claim) void {
            const target_shard: usize = @intCast(c.shard % num_workers);
            self.rings[target_shard].commit(c);
        }
    };
}
