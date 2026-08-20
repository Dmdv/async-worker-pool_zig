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
    capacity: usize,
    reserved_size: usize,

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
            .capacity = capacity,
            .reserved_size = 0,
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
                self.reserved_size = size;
                return self.buffer[wa .. wa + size];
            }

            const ra = self.read_a.load(.acquire);
            self.cached_read_a = ra;
            if (ra > size) {
                self.write_b.store(0, .monotonic);
                self.is_b_active.store(true, .release);
                self.reserved_size = size;
                return self.buffer[0..size];
            }
            return null;
        } else {
            if (self.is_reading_b.load(.acquire)) {
                const wb = self.write_b.load(.monotonic);
                self.write_a.store(wb, .release);
                self.is_b_active.store(false, .release);

                if (self.capacity - wb >= size) {
                    self.reserved_size = size;
                    return self.buffer[wb .. wb + size];
                }
                return null;
            }

            const wb = self.write_b.load(.monotonic);
            const ra = self.read_a.load(.acquire);
            self.cached_read_a = ra;
            if (ra > wb and ra - wb > size) {
                self.reserved_size = size;
                return self.buffer[wb .. wb + size];
            }
            return null;
        }
    }

    pub inline fn commit(self: *DynamicBip, size: usize) bool {
        if (size == 0 or size > self.reserved_size) return false;
        self.reserved_size = 0;
        if (!self.is_b_active.load(.monotonic)) {
            const wa = self.write_a.load(.monotonic);
            self.write_a.store(wa + size, .release);
        } else {
            const wb = self.write_b.load(.monotonic);
            self.write_b.store(wb + size, .release);
        }
        return true;
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

    pub inline fn consume(self: *DynamicBip, size: usize) bool {
        if (size == 0) return false;
        if (!self.is_reading_b.load(.monotonic)) {
            const ra = self.read_a.load(.monotonic);
            const wa = self.write_a.load(.acquire);
            if (ra >= wa) return false;
            const available = wa - ra;
            const to_consume = @min(size, available);
            const new_ra = ra + to_consume;
            if (new_ra >= wa) {
                if (self.is_b_active.load(.acquire)) {
                    self.read_a.store(0, .release);
                    self.is_reading_b.store(true, .release);
                    return true;
                }
                self.read_a.store(wa, .release);
            } else {
                self.read_a.store(new_ra, .release);
            }
            return true;
        } else {
            const ra = self.read_a.load(.monotonic);
            if (self.is_b_active.load(.acquire)) {
                const wb = self.write_b.load(.acquire);
                if (ra >= wb) return false;
                const to_consume = @min(size, wb - ra);
                self.read_a.store(ra + to_consume, .release);
                return true;
            } else {
                self.is_reading_b.store(false, .release);
                const wa = self.write_a.load(.acquire);
                if (ra >= wa) return false;
                const to_consume = @min(size, wa - ra);
                self.read_a.store(ra + to_consume, .release);
                return true;
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

pub export fn awp_zig_bip_commit(bip_ptr: ?*anyopaque, size: usize) callconv(.c) c_int {
    if (bip_ptr == null or size == 0) return -22;
    const bip: *DynamicBip = @ptrCast(@alignCast(bip_ptr.?));
    if (bip.commit(size)) {
        return 0;
    }
    return -22; // EINVAL: oversized or unreserved commit
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

pub export fn awp_zig_bip_consume(bip_ptr: ?*anyopaque, size: usize) callconv(.c) c_int {
    if (bip_ptr == null or size == 0) return -22;
    const bip: *DynamicBip = @ptrCast(@alignCast(bip_ptr.?));
    if (bip.consume(size)) {
        return 0;
    }
    return -22; // EINVAL: empty or invalid consume
}

pub fn DynamicSpscRing(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []T,
        head: std.atomic.Value(usize) align(64),
        cached_tail: usize align(64),
        tail: std.atomic.Value(usize) align(64),
        cached_head: usize align(64),
        capacity: usize align(64),
        mask: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (!std.math.isPowerOfTwo(capacity) or capacity < 2) return error.InvalidCapacity;
            const items = try allocator.alloc(T, capacity);
            return Self{
                .items = items,
                .head = std.atomic.Value(usize).init(0),
                .cached_tail = 0,
                .tail = std.atomic.Value(usize).init(0),
                .cached_head = 0,
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
    buffer_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, buffer_capacity: usize, desc_capacity: usize) !*DynamicBipRing {
        if (!std.math.isPowerOfTwo(buffer_capacity) or buffer_capacity < 64 or buffer_capacity > std.math.maxInt(u32)) return error.InvalidCapacity;
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
        return self.buffer[desc.offset..end_offset];
    }

    pub inline fn releasePacket(self: *DynamicBipRing, desc: root.PacketDescriptor) void {
        const end_offset = desc.offset + desc.len;
        self.read_offset.store(end_offset, .release);
    }
};

pub export fn awp_zig_bipring_create(buffer_capacity: usize, desc_capacity: usize, out_ring: *?*anyopaque) callconv(.c) c_int {
    if (!std.math.isPowerOfTwo(buffer_capacity) or buffer_capacity < 64 or buffer_capacity > std.math.maxInt(u32)) return -22;
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
    if (ring_ptr == null or len == 0 or payload == null) return -22;
    const ring: *DynamicBipRing = @ptrCast(@alignCast(ring_ptr.?));
    if (ring.pushPacket(payload.?[0..len], timestamp_ns)) {
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

pub export fn awp_zig_bipring_release(ring_ptr: ?*anyopaque, desc: *const root.PacketDescriptor) callconv(.c) void {
    if (ring_ptr) |ptr| {
        const ring: *DynamicBipRing = @ptrCast(@alignCast(ptr));
        ring.releasePacket(desc.*);
    }
}

// -----------------------------------------------------------------------------------------
// Phase 4: Hybrid Fast-Path Trading Reactor & Off-Path Worker Pipeline C ABI
// -----------------------------------------------------------------------------------------

pub const DynamicReactor = struct {
    allocator: std.mem.Allocator,
    best_bid_price: f64,
    best_ask_price: f64,
    best_bid_qty: f64,
    best_ask_qty: f64,
    last_seq: u64,
    next_order_id: u64,
    processed_ticks: u64,
    generated_signals: u64,
    overrun_count: std.atomic.Value(u64) align(64),

    risk_ring: ?*DynamicSpscRing(root.OrderSignal64) align(64),
    audit_ring: ?*DynamicSpscRing(root.OrderSignal64),
    telemetry_ring: ?*DynamicSpscRing(root.OrderSignal64),

    pub fn init(allocator: std.mem.Allocator) !*DynamicReactor {
        const self = try allocator.create(DynamicReactor);
        self.* = .{
            .allocator = allocator,
            .best_bid_price = 0,
            .best_ask_price = 0,
            .best_bid_qty = 0,
            .best_ask_qty = 0,
            .last_seq = 0,
            .next_order_id = 1,
            .processed_ticks = 0,
            .generated_signals = 0,
            .overrun_count = std.atomic.Value(u64).init(0),
            .risk_ring = null,
            .audit_ring = null,
            .telemetry_ring = null,
        };
        return self;
    }

    pub fn deinit(self: *DynamicReactor) void {
        self.allocator.destroy(self);
    }

    pub inline fn processTickWithTs(
        self: *DynamicReactor,
        update: root.BookUpdate64,
        now_ns: u64,
        out_signal: *root.OrderSignal64,
    ) bool {
        self.processed_ticks += 1;
        self.best_bid_price = update.bid_price;
        self.best_ask_price = update.ask_price;
        self.best_bid_qty = update.bid_qty;
        self.best_ask_qty = update.ask_qty;
        self.last_seq = update.seq;

        if (update.ask_price > update.bid_price and update.bid_price > 0) {
            const sig = root.OrderSignal64{
                .timestamp_ns = now_ns,
                .ingress_ts_ns = update.timestamp_ns,
                .order_id = self.next_order_id,
                .price = update.bid_price,
                .qty = update.bid_qty,
                .symbol_id = update.symbol_id,
                .side = 0, // Buy
                .action = 1, // New
                .flags = 0x02, // PostOnly
                ._reserved = [_]u8{0} ** 8,
            };
            self.next_order_id +%= 1;
            self.generated_signals += 1;

            out_signal.* = sig;
            self.fanOutNonBlocking(sig);
            return true;
        }
        return false;
    }

    pub inline fn processTick(self: *DynamicReactor, update: root.BookUpdate64, out_signal: *root.OrderSignal64) bool {
        return self.processTickWithTs(update, root.nowNs(), out_signal);
    }

    inline fn fanOutNonBlocking(self: *DynamicReactor, signal: root.OrderSignal64) void {
        if (self.risk_ring) |r| {
            if (r.claim()) |slot| {
                slot.* = signal;
                r.commit();
            } else {
                _ = self.overrun_count.fetchAdd(1, .monotonic);
            }
        }
        if (self.audit_ring) |r| {
            if (r.claim()) |slot| {
                slot.* = signal;
                r.commit();
            } else {
                _ = self.overrun_count.fetchAdd(1, .monotonic);
            }
        }
        if (self.telemetry_ring) |r| {
            if (r.claim()) |slot| {
                slot.* = signal;
                r.commit();
            } else {
                _ = self.overrun_count.fetchAdd(1, .monotonic);
            }
        }
    }
};

pub const DynamicOffPath = struct {
    allocator: std.mem.Allocator,
    risk_ring: DynamicSpscRing(root.OrderSignal64),
    audit_ring: DynamicSpscRing(root.OrderSignal64),
    telemetry_ring: DynamicSpscRing(root.OrderSignal64),

    running: std.atomic.Value(bool) align(64),
    risk_processed: std.atomic.Value(u64) align(64),
    audit_processed: std.atomic.Value(u64) align(64),
    telemetry_processed: std.atomic.Value(u64) align(64),
    total_latency_ns: std.atomic.Value(u64) align(64),

    risk_thread: ?std.Thread = null,
    audit_thread: ?std.Thread = null,
    telemetry_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*DynamicOffPath {
        if (!std.math.isPowerOfTwo(capacity) or capacity < 2) return error.InvalidCapacity;
        const self = try allocator.create(DynamicOffPath);
        errdefer allocator.destroy(self);

        var risk_ring = try DynamicSpscRing(root.OrderSignal64).init(allocator, capacity);
        errdefer risk_ring.deinit();

        var audit_ring = try DynamicSpscRing(root.OrderSignal64).init(allocator, capacity);
        errdefer audit_ring.deinit();

        var telemetry_ring = try DynamicSpscRing(root.OrderSignal64).init(allocator, capacity);
        errdefer telemetry_ring.deinit();

        self.* = .{
            .allocator = allocator,
            .risk_ring = risk_ring,
            .audit_ring = audit_ring,
            .telemetry_ring = telemetry_ring,
            .running = std.atomic.Value(bool).init(false),
            .risk_processed = std.atomic.Value(u64).init(0),
            .audit_processed = std.atomic.Value(u64).init(0),
            .telemetry_processed = std.atomic.Value(u64).init(0),
            .total_latency_ns = std.atomic.Value(u64).init(0),
            .risk_thread = null,
            .audit_thread = null,
            .telemetry_thread = null,
        };
        return self;
    }

    pub fn deinit(self: *DynamicOffPath) void {
        self.stop();
        self.telemetry_ring.deinit();
        self.audit_ring.deinit();
        self.risk_ring.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *DynamicOffPath) !void {
        if (self.running.swap(true, .acq_rel)) return;
        errdefer self.stop();

        self.risk_thread = try std.Thread.spawn(.{}, riskWorkerLoop, .{self});
        self.audit_thread = try std.Thread.spawn(.{}, auditWorkerLoop, .{self});
        self.telemetry_thread = try std.Thread.spawn(.{}, telemetryWorkerLoop, .{self});
    }

    pub fn stop(self: *DynamicOffPath) void {
        if (!self.running.swap(false, .acq_rel)) return;

        if (self.risk_thread) |t| {
            t.join();
            self.risk_thread = null;
        }
        if (self.audit_thread) |t| {
            t.join();
            self.audit_thread = null;
        }
        if (self.telemetry_thread) |t| {
            t.join();
            self.telemetry_thread = null;
        }
    }

    fn riskWorkerLoop(self: *DynamicOffPath) void {
        root.pinToPerformanceCores();
        var position: f64 = 0;
        var notional: f64 = 0;
        _ = &position;
        _ = &notional;

        while (self.running.load(.acquire)) {
            var batch_count: u64 = 0;
            while (self.risk_ring.popValue()) |sig| {
                batch_count += 1;
                if (sig.side == 0) {
                    position += sig.qty;
                } else {
                    position -= sig.qty;
                }
                notional += sig.price * sig.qty;
            }
            if (batch_count > 0) {
                _ = self.risk_processed.fetchAdd(batch_count, .monotonic);
            } else {
                std.atomic.spinLoopHint();
            }
        }
        var exit_count: u64 = 0;
        while (self.risk_ring.popValue()) |sig| {
            exit_count += 1;
            if (sig.side == 0) {
                position += sig.qty;
            } else {
                position -= sig.qty;
            }
            notional += sig.price * sig.qty;
        }
        if (exit_count > 0) {
            _ = self.risk_processed.fetchAdd(exit_count, .monotonic);
        }
    }

    fn auditWorkerLoop(self: *DynamicOffPath) void {
        root.pinToPerformanceCores();
        var checksum: u64 = 0;
        _ = &checksum;

        while (self.running.load(.acquire)) {
            var batch_count: u64 = 0;
            while (self.audit_ring.popValue()) |sig| {
                batch_count += 1;
                checksum +%= sig.order_id ^ sig.timestamp_ns;
            }
            if (batch_count > 0) {
                _ = self.audit_processed.fetchAdd(batch_count, .monotonic);
            } else {
                std.atomic.spinLoopHint();
            }
        }
        var exit_count: u64 = 0;
        while (self.audit_ring.popValue()) |sig| {
            exit_count += 1;
            checksum +%= sig.order_id ^ sig.timestamp_ns;
        }
        if (exit_count > 0) {
            _ = self.audit_processed.fetchAdd(exit_count, .monotonic);
        }
    }

    fn telemetryWorkerLoop(self: *DynamicOffPath) void {
        root.pinToPerformanceCores();
        while (self.running.load(.acquire)) {
            var batch_count: u64 = 0;
            var batch_lat: u64 = 0;
            while (self.telemetry_ring.popValue()) |sig| {
                batch_count += 1;
                if (sig.timestamp_ns >= sig.ingress_ts_ns) {
                    batch_lat += (sig.timestamp_ns - sig.ingress_ts_ns);
                }
            }
            if (batch_count > 0) {
                if (batch_lat > 0) {
                    _ = self.total_latency_ns.fetchAdd(batch_lat, .monotonic);
                }
                _ = self.telemetry_processed.fetchAdd(batch_count, .monotonic);
            } else {
                std.atomic.spinLoopHint();
            }
        }
        var exit_count: u64 = 0;
        var exit_lat: u64 = 0;
        while (self.telemetry_ring.popValue()) |sig| {
            exit_count += 1;
            if (sig.timestamp_ns >= sig.ingress_ts_ns) {
                exit_lat +%= (sig.timestamp_ns - sig.ingress_ts_ns);
            }
        }
        if (exit_count > 0) {
            if (exit_lat > 0) {
                _ = self.total_latency_ns.fetchAdd(exit_lat, .monotonic);
            }
            _ = self.telemetry_processed.fetchAdd(exit_count, .monotonic);
        }
    }
};

pub export fn awp_zig_reactor_create(out_reactor: ?*?*anyopaque) callconv(.c) c_int {
    if (out_reactor == null) return -22;
    const reactor = DynamicReactor.init(std.heap.c_allocator) catch return -12;
    out_reactor.?.* = @ptrCast(reactor);
    return 0;
}

pub export fn awp_zig_reactor_destroy(reactor_ptr: ?*anyopaque) callconv(.c) void {
    if (reactor_ptr) |ptr| {
        const reactor: *DynamicReactor = @ptrCast(@alignCast(ptr));
        reactor.deinit();
    }
}

pub export fn awp_zig_reactor_process_tick(reactor_ptr: ?*anyopaque, update: ?*const root.BookUpdate64, out_signal: ?*root.OrderSignal64) callconv(.c) c_int {
    if (reactor_ptr == null or update == null or out_signal == null) return -22;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    if (reactor.processTick(update.?.*, out_signal.?)) {
        return 0; // Signal generated
    }
    return 1; // Evaluated cleanly, no signal generated
}

pub export fn awp_zig_reactor_process_tick_with_ts(
    reactor_ptr: ?*anyopaque,
    update: ?*const root.BookUpdate64,
    now_ns: u64,
    out_signal: ?*root.OrderSignal64,
) callconv(.c) c_int {
    if (reactor_ptr == null or update == null or out_signal == null) return -22;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    if (reactor.processTickWithTs(update.?.*, now_ns, out_signal.?)) {
        return 0; // Signal generated
    }
    return 1; // Evaluated cleanly, no signal generated
}

pub export fn awp_zig_reactor_bind_risk_ring(reactor_ptr: ?*anyopaque, ring_ptr: ?*anyopaque) callconv(.c) c_int {
    if (reactor_ptr == null) return -22;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    if (ring_ptr) |ptr| {
        reactor.risk_ring = @ptrCast(@alignCast(ptr));
    } else {
        reactor.risk_ring = null;
    }
    return 0;
}

pub export fn awp_zig_reactor_bind_audit_ring(reactor_ptr: ?*anyopaque, ring_ptr: ?*anyopaque) callconv(.c) c_int {
    if (reactor_ptr == null) return -22;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    if (ring_ptr) |ptr| {
        reactor.audit_ring = @ptrCast(@alignCast(ptr));
    } else {
        reactor.audit_ring = null;
    }
    return 0;
}

pub export fn awp_zig_reactor_bind_telemetry_ring(reactor_ptr: ?*anyopaque, ring_ptr: ?*anyopaque) callconv(.c) c_int {
    if (reactor_ptr == null) return -22;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    if (ring_ptr) |ptr| {
        reactor.telemetry_ring = @ptrCast(@alignCast(ptr));
    } else {
        reactor.telemetry_ring = null;
    }
    return 0;
}

pub export fn awp_zig_reactor_get_overruns(reactor_ptr: ?*anyopaque) callconv(.c) u64 {
    if (reactor_ptr == null) return 0;
    const reactor: *DynamicReactor = @ptrCast(@alignCast(reactor_ptr.?));
    return reactor.overrun_count.load(.acquire);
}

pub export fn awp_zig_offpath_create(capacity: usize, out_offpath: ?*?*anyopaque) callconv(.c) c_int {
    if (out_offpath == null) return -22;
    if (!std.math.isPowerOfTwo(capacity) or capacity < 2) return -22;
    const offpath = DynamicOffPath.init(std.heap.c_allocator, capacity) catch return -12;
    out_offpath.?.* = @ptrCast(offpath);
    return 0;
}

pub export fn awp_zig_offpath_start(offpath_ptr: ?*anyopaque) callconv(.c) c_int {
    if (offpath_ptr == null) return -22;
    const offpath: *DynamicOffPath = @ptrCast(@alignCast(offpath_ptr.?));
    offpath.start() catch return -12;
    return 0;
}

pub export fn awp_zig_offpath_stop(offpath_ptr: ?*anyopaque) callconv(.c) void {
    if (offpath_ptr) |ptr| {
        const offpath: *DynamicOffPath = @ptrCast(@alignCast(ptr));
        offpath.stop();
    }
}

pub export fn awp_zig_offpath_destroy(offpath_ptr: ?*anyopaque) callconv(.c) void {
    if (offpath_ptr) |ptr| {
        const offpath: *DynamicOffPath = @ptrCast(@alignCast(ptr));
        offpath.deinit();
    }
}

pub export fn awp_zig_offpath_get_risk_ring(offpath_ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (offpath_ptr == null) return null;
    const offpath: *DynamicOffPath = @ptrCast(@alignCast(offpath_ptr.?));
    return @ptrCast(&offpath.risk_ring);
}

pub export fn awp_zig_offpath_get_audit_ring(offpath_ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (offpath_ptr == null) return null;
    const offpath: *DynamicOffPath = @ptrCast(@alignCast(offpath_ptr.?));
    return @ptrCast(&offpath.audit_ring);
}

pub export fn awp_zig_offpath_get_telemetry_ring(offpath_ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (offpath_ptr == null) return null;
    const offpath: *DynamicOffPath = @ptrCast(@alignCast(offpath_ptr.?));
    return @ptrCast(&offpath.telemetry_ring);
}

pub export fn awp_zig_offpath_get_processed(
    offpath_ptr: ?*anyopaque,
    out_risk: ?*u64,
    out_audit: ?*u64,
    out_telemetry: ?*u64,
) callconv(.c) void {
    if (offpath_ptr == null) return;
    const offpath: *DynamicOffPath = @ptrCast(@alignCast(offpath_ptr.?));
    if (out_risk) |p| p.* = offpath.risk_processed.load(.acquire);
    if (out_audit) |p| p.* = offpath.audit_processed.load(.acquire);
    if (out_telemetry) |p| p.* = offpath.telemetry_processed.load(.acquire);
}
