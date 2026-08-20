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
        if (!std.math.isPowerOfTwo(capacity) or capacity < 2) return error.InvalidCapacity;
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
                f.flags = 0;
                f.feed[0] = 0;
                f.symbol[0] = 0;
                f.payload_len = 0;
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
            if (data.flags & root.AWP_FLAG_DROPPED == 0) {
                _ = callback(data, user);
            }
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

        var initialized_rings: usize = 0;
        errdefer {
            for (rings[0..initialized_rings]) |*r| {
                r.deinit();
            }
        }

        for (rings) |*r| {
            r.* = try DynamicRing.init(allocator, queue_capacity);
            initialized_rings += 1;
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
                for (rings) |*r| {
                    r.deinit();
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
    if (!std.math.isPowerOfTwo(cap) or cap < 2) return -22; // EINVAL

    const pool = DynamicPool.init(
        std.heap.c_allocator,
        workers,
        cap,
        callback.?,
        user,
    ) catch |err| {
        if (err == error.InvalidCapacity) return -22; // EINVAL
        return -12; // ENOMEM
    };

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

pub const DynamicBip = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    write_a: std.atomic.Value(usize) align(64),
    write_b: std.atomic.Value(usize),
    is_b_active: std.atomic.Value(bool),
    cached_read_a: usize,

    read_a: std.atomic.Value(usize) align(64),
    is_reading_b: std.atomic.Value(bool),
    cached_write_a: usize,
    cached_write_b: usize,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*DynamicBip {
        if (!std.math.isPowerOfTwo(capacity) or capacity < 64) return error.InvalidCapacity;
        const self = try allocator.create(DynamicBip);
        errdefer allocator.destroy(self);

        const buf = try allocator.alloc(u8, capacity);
        errdefer allocator.free(buf);

        self.* = .{
            .allocator = allocator,
            .buffer = buf,
            .write_a = std.atomic.Value(usize).init(0),
            .write_b = std.atomic.Value(usize).init(0),
            .is_b_active = std.atomic.Value(bool).init(false),
            .cached_read_a = 0,
            .read_a = std.atomic.Value(usize).init(0),
            .is_reading_b = std.atomic.Value(bool).init(false),
            .cached_write_a = 0,
            .cached_write_b = 0,
            .capacity = capacity,
        };
        return self;
    }

    pub fn deinit(self: *DynamicBip) void {
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    pub inline fn reserve(self: *DynamicBip, size: usize) ?[]u8 {
        if (size == 0 or size > self.capacity) return null;

        if (!self.is_b_active.load(.monotonic)) {
            const wa = self.write_a.load(.monotonic);
            if (self.capacity - wa >= size) {
                return self.buffer[wa .. wa + size];
            }

            const ra = self.read_a.load(.acquire);
            self.cached_read_a = ra;
            if (ra > size) {
                self.write_b.store(0, .monotonic);
                self.is_b_active.store(true, .release);
                return self.buffer[0..size];
            }
            return null;
        } else {
            if (self.is_reading_b.load(.acquire)) {
                const wb = self.write_b.load(.monotonic);
                self.write_a.store(wb, .release);
                self.write_b.store(0, .monotonic);
                self.is_b_active.store(false, .release);

                if (self.capacity - wb >= size) {
                    return self.buffer[wb .. wb + size];
                }
                return null;
            }

            const wb = self.write_b.load(.monotonic);
            const ra = self.read_a.load(.acquire);
            self.cached_read_a = ra;
            if (ra > wb and ra - wb > size) {
                return self.buffer[wb .. wb + size];
            }
            return null;
        }
    }

    pub inline fn commit(self: *DynamicBip, size: usize) void {
        if (!self.is_b_active.load(.monotonic)) {
            const wa = self.write_a.load(.monotonic);
            self.write_a.store(wa + size, .release);
        } else {
            const wb = self.write_b.load(.monotonic);
            self.write_b.store(wb + size, .release);
        }
    }

    pub inline fn peek(self: *DynamicBip) ?[]const u8 {
        if (!self.is_reading_b.load(.monotonic)) {
            const ra = self.read_a.load(.monotonic);
            const wa = self.write_a.load(.acquire);

            if (ra < wa) {
                return self.buffer[ra..wa];
            }

            if (self.is_b_active.load(.acquire)) {
                const wb = self.write_b.load(.acquire);
                if (wb > 0) {
                    self.read_a.store(0, .release);
                    self.is_reading_b.store(true, .release);
                    return self.buffer[0..wb];
                }
            }

            return null;
        } else {
            const ra = self.read_a.load(.monotonic);
            if (self.is_b_active.load(.acquire)) {
                const wb = self.write_b.load(.acquire);
                if (ra < wb) return self.buffer[ra..wb];
            } else {
                self.is_reading_b.store(false, .release);
                const wa = self.write_a.load(.acquire);
                if (ra < wa) return self.buffer[ra..wa];
            }
            return null;
        }
    }

    pub inline fn consume(self: *DynamicBip, size: usize) void {
        const ra = self.read_a.load(.monotonic);
        const new_ra = ra + size;

        if (!self.is_reading_b.load(.monotonic)) {
            const wa = self.write_a.load(.monotonic);
            if (new_ra >= wa) {
                if (self.is_b_active.load(.acquire)) {
                    self.read_a.store(0, .release);
                    self.is_reading_b.store(true, .release);
                    return;
                }
                self.read_a.store(wa, .release);
            } else {
                self.read_a.store(new_ra, .release);
            }
        } else {
            if (self.is_b_active.load(.acquire)) {
                const wb = self.write_b.load(.monotonic);
                if (new_ra >= wb) {
                    self.read_a.store(wb, .release);
                } else {
                    self.read_a.store(new_ra, .release);
                }
            } else {
                self.is_reading_b.store(false, .release);
                self.read_a.store(new_ra, .release);
            }
        }
    }
};

pub export fn awp_zig_bip_create(capacity: usize, out_bip: *?*anyopaque) callconv(.c) c_int {
    if (!std.math.isPowerOfTwo(capacity) or capacity < 64) return -22;
    const bip = DynamicBip.init(std.heap.c_allocator, capacity) catch return -12;
    out_bip.* = @ptrCast(bip);
    return 0;
}

pub export fn awp_zig_bip_destroy(bip_ptr: ?*anyopaque) callconv(.c) void {
    if (bip_ptr) |ptr| {
        const bip: *DynamicBip = @ptrCast(@alignCast(ptr));
        bip.deinit();
    }
}

pub export fn awp_zig_bip_reserve(bip_ptr: ?*anyopaque, size: usize, out_ptr: *[*]u8) callconv(.c) c_int {
    if (bip_ptr == null or size == 0) return -22;
    const bip: *DynamicBip = @ptrCast(@alignCast(bip_ptr.?));
    if (bip.reserve(size)) |slice| {
        out_ptr.* = slice.ptr;
        return 0;
    }
    return -11; // EAGAIN / Full
}

pub export fn awp_zig_bip_commit(bip_ptr: ?*anyopaque, size: usize) callconv(.c) void {
    if (bip_ptr) |ptr| {
        const bip: *DynamicBip = @ptrCast(@alignCast(ptr));
        bip.commit(size);
    }
}

pub export fn awp_zig_bip_peek(bip_ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) c_int {
    if (bip_ptr == null) return -22;
    const bip: *DynamicBip = @ptrCast(@alignCast(bip_ptr.?));
    if (bip.peek()) |slice| {
        out_ptr.* = slice.ptr;
        out_len.* = slice.len;
        return 0;
    }
    return -11; // EAGAIN / Empty
}

pub export fn awp_zig_bip_consume(bip_ptr: ?*anyopaque, size: usize) callconv(.c) void {
    if (bip_ptr) |ptr| {
        const bip: *DynamicBip = @ptrCast(@alignCast(ptr));
        bip.consume(size);
    }
}

pub fn DynamicSpscRing(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        head: std.atomic.Value(usize) align(64),
        tail: std.atomic.Value(usize) align(64),
        cached_head: usize,
        cached_tail: usize,
        capacity: usize,
        mask: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (!std.math.isPowerOfTwo(capacity) or capacity < 2) return error.InvalidCapacity;
            const items = try allocator.alloc(T, capacity);
            return Self{
                .items = items,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
                .cached_head = 0,
                .cached_tail = 0,
                .capacity = capacity,
                .mask = capacity - 1,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
        }

        pub inline fn claim(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            var tail = self.cached_tail;
            if (head -% tail >= self.capacity) {
                tail = self.tail.load(.acquire);
                self.cached_tail = tail;
                if (head -% tail >= self.capacity) return null;
            }
            return &self.items[head & self.mask];
        }

        pub inline fn commit(self: *Self) void {
            const head = self.head.load(.monotonic);
            self.head.store(head +% 1, .release);
        }

        pub inline fn popValue(self: *Self) ?T {
            const tail = self.tail.load(.monotonic);
            var head = self.cached_head;
            if (tail == head) {
                head = self.head.load(.acquire);
                self.cached_head = head;
                if (tail == head) return null;
            }
            const val = self.items[tail & self.mask];
            self.tail.store(tail +% 1, .release);
            return val;
        }
    };
}

pub const DynamicBipRing = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    desc_ring: DynamicSpscRing(root.PacketDescriptor),
    write_offset: std.atomic.Value(usize) align(64),
    cached_read_offset: usize,
    read_offset: std.atomic.Value(usize) align(64),
    cached_write_offset: usize,
    buffer_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_capacity: usize, desc_capacity: usize) !*DynamicBipRing {
        if (!std.math.isPowerOfTwo(buffer_capacity) or buffer_capacity < 64) return error.InvalidCapacity;
        if (!std.math.isPowerOfTwo(desc_capacity) or desc_capacity < 2) return error.InvalidCapacity;

        const self = try allocator.create(DynamicBipRing);
        errdefer allocator.destroy(self);

        const buf = try allocator.alloc(u8, buffer_capacity);
        errdefer allocator.free(buf);

        const desc_ring = try DynamicSpscRing(root.PacketDescriptor).init(allocator, desc_capacity);

        self.* = .{
            .allocator = allocator,
            .buffer = buf,
            .desc_ring = desc_ring,
            .write_offset = std.atomic.Value(usize).init(0),
            .cached_read_offset = 0,
            .read_offset = std.atomic.Value(usize).init(0),
            .cached_write_offset = 0,
            .buffer_capacity = buffer_capacity,
        };
        return self;
    }

    pub fn deinit(self: *DynamicBipRing) void {
        self.desc_ring.deinit();
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    pub inline fn pushPacket(self: *DynamicBipRing, payload: []const u8, timestamp: u64) bool {
        if (payload.len == 0 or payload.len > self.buffer_capacity) return false;
        const desc_slot = self.desc_ring.claim() orelse return false;

        var wo = self.write_offset.load(.monotonic);
        var ro = self.cached_read_offset;
        var target_offset: usize = 0;

        if (wo >= ro) {
            if (self.buffer_capacity - wo >= payload.len) {
                target_offset = wo;
                wo += payload.len;
            } else {
                ro = self.read_offset.load(.acquire);
                self.cached_read_offset = ro;
                if (ro > payload.len) {
                    target_offset = 0;
                    wo = payload.len;
                } else {
                    return false;
                }
            }
        } else {
            if (ro - wo > payload.len) {
                target_offset = wo;
                wo += payload.len;
            } else {
                ro = self.read_offset.load(.acquire);
                self.cached_read_offset = ro;
                if (ro > wo and ro - wo > payload.len) {
                    target_offset = wo;
                    wo += payload.len;
                } else {
                    return false;
                }
            }
        }

        @memcpy(self.buffer[target_offset .. target_offset + payload.len], payload);
        self.write_offset.store(wo, .release);

        desc_slot.* = root.PacketDescriptor{
            .timestamp_ns = timestamp,
            .offset = @intCast(target_offset),
            .len = @intCast(payload.len),
        };
        self.desc_ring.commit();
        return true;
    }

    pub inline fn popPacket(self: *DynamicBipRing, out_desc: *root.PacketDescriptor) ?[]const u8 {
        const desc = self.desc_ring.popValue() orelse return null;
        out_desc.* = desc;
        const end_offset = desc.offset + desc.len;
        self.read_offset.store(end_offset, .release);
        return self.buffer[desc.offset..end_offset];
    }
};

pub export fn awp_zig_bipring_create(buffer_capacity: usize, desc_capacity: usize, out_ring: *?*anyopaque) callconv(.c) c_int {
    if (!std.math.isPowerOfTwo(buffer_capacity) or buffer_capacity < 64) return -22;
    if (!std.math.isPowerOfTwo(desc_capacity) or desc_capacity < 2) return -22;
    const ring = DynamicBipRing.init(std.heap.c_allocator, buffer_capacity, desc_capacity) catch return -12;
    out_ring.* = @ptrCast(ring);
    return 0;
}

pub export fn awp_zig_bipring_destroy(ring_ptr: ?*anyopaque) callconv(.c) void {
    if (ring_ptr) |ptr| {
        const ring: *DynamicBipRing = @ptrCast(@alignCast(ptr));
        ring.deinit();
    }
}

pub export fn awp_zig_bipring_push(ring_ptr: ?*anyopaque, payload: ?[*]const u8, len: usize, timestamp_ns: u64) callconv(.c) c_int {
    if (ring_ptr == null or (payload == null and len > 0)) return -22;
    const ring: *DynamicBipRing = @ptrCast(@alignCast(ring_ptr.?));
    const slice = if (payload) |p| p[0..len] else &[_]u8{};
    if (ring.pushPacket(slice, timestamp_ns)) {
        return 0;
    }
    return -11; // EAGAIN / Full
}

pub export fn awp_zig_bipring_pop(ring_ptr: ?*anyopaque, out_payload: *[*]const u8, out_len: *usize, out_desc: *root.PacketDescriptor) callconv(.c) c_int {
    if (ring_ptr == null) return -22;
    const ring: *DynamicBipRing = @ptrCast(@alignCast(ring_ptr.?));
    if (ring.popPacket(out_desc)) |slice| {
        out_payload.* = slice.ptr;
        out_len.* = slice.len;
        return 0;
    }
    return -11; // EAGAIN / Empty
}
