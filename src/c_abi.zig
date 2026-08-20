const std = @import("std");
const types = @import("types.zig");
const root = @import("root.zig");
pub const Frame = types.Frame;
pub const Claim = types.Claim;

pub const DynamicRing = struct {
    const Cell = struct {
        sequence: std.atomic.Value(usize),
    };

    capacity: usize,
    mask: usize,
    cells: []Cell,
    frames: []Frame,
    enqueue_pos: std.atomic.Value(usize) align(64),
    dequeue_pos: std.atomic.Value(usize) align(64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !DynamicRing {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
        const cells = try allocator.alloc(Cell, capacity);
        const frames = try allocator.alloc(Frame, capacity);
        for (cells, 0..) |*cell, i| {
            cell.sequence = std.atomic.Value(usize).init(i);
        }
        return DynamicRing{
            .capacity = capacity,
            .mask = capacity - 1,
            .cells = cells,
            .frames = frames,
            .enqueue_pos = std.atomic.Value(usize).init(0),
            .dequeue_pos = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicRing) void {
        self.allocator.free(self.frames);
        self.allocator.free(self.cells);
    }

    pub inline fn claim(self: *DynamicRing, shard: u32) ?Claim {
        var pos = self.enqueue_pos.load(.monotonic);
        while (true) {
            const cell = &self.cells[pos & self.mask];
            const seq = cell.sequence.load(.acquire);
            const dif: isize = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));

            if (dif == 0) {
                if (self.enqueue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .monotonic)) |next_pos| {
                    pos = next_pos;
                    continue;
                }
                const f = &self.frames[pos & self.mask];
                f.shard = shard;
                f.submit_ns = root.nowNs();
                @prefetch(&self.frames[(pos + 1) & self.mask], .{ .rw = .write, .locality = 3, .cache = .data });
                return Claim{
                    .frame = f,
                    .shard = shard,
                    .pos = pos,
                };
            } else if (dif < 0) {
                @branchHint(.unlikely);
                return null;
            } else {
                pos = self.enqueue_pos.load(.monotonic);
            }
        }
    }

    pub inline fn commit(self: *DynamicRing, c: Claim) void {
        const cell = &self.cells[c.pos & self.mask];
        cell.sequence.store(c.pos + 1, .release);
    }

    pub inline fn processOne(self: *DynamicRing, callback: CCallback, user: ?*anyopaque) bool {
        const pos = self.dequeue_pos.load(.monotonic);
        const cell = &self.cells[pos & self.mask];
        const seq = cell.sequence.load(.acquire);
        const dif: isize = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));

        if (dif == 0) {
            self.dequeue_pos.store(pos + 1, .monotonic);
            const data = &self.frames[pos & self.mask];
            @prefetch(&self.frames[(pos + 1) & self.mask], .{ .rw = .read, .locality = 3, .cache = .data });
            _ = callback(data, user);
            cell.sequence.store(pos + self.capacity, .release);
            return true;
        } else {
            @branchHint(.unlikely);
            return false;
        }
    }
};

pub const CCallback = *const fn (frame: *const Frame, user: ?*anyopaque) callconv(.c) i32;

pub const DynamicPool = struct {
    allocator: std.mem.Allocator,
    num_workers: usize,
    rings: []DynamicRing,
    threads: []std.Thread,
    running: std.atomic.Value(bool),
    callback: CCallback,
    user: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        num_workers: usize,
        queue_capacity: usize,
        callback: CCallback,
        user: ?*anyopaque,
    ) !*DynamicPool {
        const self = try allocator.create(DynamicPool);
        errdefer allocator.destroy(self);

        const rings = try allocator.alloc(DynamicRing, num_workers);
        errdefer allocator.free(rings);

        for (rings) |*r| {
            r.* = try DynamicRing.init(allocator, queue_capacity);
        }

        const threads = try allocator.alloc(std.Thread, num_workers);
        errdefer allocator.free(threads);

        self.* = .{
            .allocator = allocator,
            .num_workers = num_workers,
            .rings = rings,
            .threads = threads,
            .running = std.atomic.Value(bool).init(true),
            .callback = callback,
            .user = user,
        };

        for (0..num_workers) |i| {
            self.threads[i] = std.Thread.spawn(.{}, workerLoop, .{ self, i }) catch |err| {
                self.running.store(false, .release);
                for (self.threads[0..i]) |t| {
                    t.join();
                }
                return err;
            };
        }

        return self;
    }

    pub fn deinit(self: *DynamicPool) void {
        self.running.store(false, .release);
        for (self.threads) |t| {
            t.join();
        }
        for (self.rings) |*r| {
            r.deinit();
        }
        self.allocator.free(self.threads);
        self.allocator.free(self.rings);
        self.allocator.destroy(self);
    }

    fn workerLoop(self: *DynamicPool, worker_id: usize) void {
        root.pinToPerformanceCores();
        const ring = &self.rings[worker_id];

        while (self.running.load(.acquire)) {
            if (!ring.processOne(self.callback, self.user)) {
                std.atomic.spinLoopHint();
            }
        }

        while (ring.processOne(self.callback, self.user)) {}
    }

    pub inline fn claim(self: *DynamicPool, shard: u32) ?Claim {
        const target: usize = @intCast(shard % self.num_workers);
        return self.rings[target].claim(@truncate(target));
    }

    pub inline fn commit(self: *DynamicPool, c: Claim) void {
        const target: usize = @intCast(c.shard % self.num_workers);
        self.rings[target].commit(c);
    }
};

// =========================================================================
// C ABI Exports (Accessible from Rust FFI, C, C++, and Go)
// =========================================================================

export fn awp_zig_pool_create(
    workers: u32,
    queue_capacity: u32,
    callback: ?CCallback,
    user: ?*anyopaque,
    out_pool: *?*anyopaque,
) callconv(.c) c_int {
    if (workers == 0 or callback == null) return -22; // EINVAL
    const cap: usize = if (queue_capacity > 0) queue_capacity else 256;

    const pool = DynamicPool.init(
        std.heap.c_allocator,
        workers,
        cap,
        callback.?,
        user,
    ) catch return -12; // ENOMEM

    out_pool.* = @ptrCast(pool);
    return 0;
}

export fn awp_zig_pool_destroy(pool_ptr: ?*anyopaque) callconv(.c) void {
    if (pool_ptr) |p| {
        const pool: *DynamicPool = @ptrCast(@alignCast(p));
        pool.deinit();
    }
}

export fn awp_zig_claim(
    pool_ptr: ?*anyopaque,
    shard: u32,
    out_claim: *Claim,
) callconv(.c) c_int {
    if (pool_ptr == null) return -22;
    const pool: *DynamicPool = @ptrCast(@alignCast(pool_ptr.?));
    if (pool.claim(shard)) |c| {
        out_claim.* = c;
        return 0;
    }
    return -11; // EAGAIN / Queue Full
}

export fn awp_zig_commit(
    pool_ptr: ?*anyopaque,
    claim_ptr: *const Claim,
) callconv(.c) c_int {
    if (pool_ptr == null) return -22;
    const pool: *DynamicPool = @ptrCast(@alignCast(pool_ptr.?));
    pool.commit(claim_ptr.*);
    return 0;
}

export fn awp_zig_submit(
    pool_ptr: ?*anyopaque,
    feed: [*:0]const u8,
    symbol: [*:0]const u8,
    payload: ?*const anyopaque,
    payload_len: usize,
    flags: u32,
) callconv(.c) c_int {
    if (pool_ptr == null) return -22;
    if (payload == null and payload_len > 0) return -22; // EINVAL
    const pool: *DynamicPool = @ptrCast(@alignCast(pool_ptr.?));

    // Simple FNV-1a hash
    var hash: u64 = 0xcbf29ce484222325;
    const feed_slice = std.mem.span(feed);
    const sym_slice = std.mem.span(symbol);

    for (feed_slice) |b| {
        hash = (hash ^ b) *% 0x100000001b3;
    }
    for (sym_slice) |b| {
        hash = (hash ^ b) *% 0x100000001b3;
    }

    const shard: u32 = @truncate(hash % pool.num_workers);

    if (pool.claim(shard)) |c| {
        const f = c.frame;
        const f_feed_len = @min(feed_slice.len, root.AWP_FEED_MAX);
        const f_sym_len = @min(sym_slice.len, root.AWP_SYMBOL_MAX);
        const f_pay_len = if (payload != null) @min(payload_len, root.AWP_PAYLOAD_MAX) else 0;

        @memcpy(f.feed[0..f_feed_len], feed_slice[0..f_feed_len]);
        f.feed[f_feed_len] = 0;

        @memcpy(f.symbol[0..f_sym_len], sym_slice[0..f_sym_len]);
        f.symbol[f_sym_len] = 0;

        if (payload != null and f_pay_len > 0) {
            const src: [*]const u8 = @ptrCast(payload.?);
            @memcpy(f.payload[0..f_pay_len], src[0..f_pay_len]);
        }
        f.payload_len = f_pay_len;
        f.flags = flags;

        pool.commit(c);
        return 0;
    } else {
        @branchHint(.unlikely);
        return -11; // EAGAIN / Queue Full (Non-blocking HFT semantics)
    }
}
