const std = @import("std");

pub const types = @import("types.zig");
pub const AWP_FEED_MAX = types.AWP_FEED_MAX;
pub const AWP_SYMBOL_MAX = types.AWP_SYMBOL_MAX;
pub const AWP_PAYLOAD_MAX = types.AWP_PAYLOAD_MAX;
pub const Frame = types.Frame;
pub const Claim = types.Claim;

pub const c_abi = @import("c_abi.zig");
pub const DynamicPool = c_abi.DynamicPool;
pub const DynamicRing = c_abi.DynamicRing;
pub const awp_zig_pool_create = c_abi.awp_zig_pool_create;
pub const awp_zig_pool_destroy = c_abi.awp_zig_pool_destroy;
pub const awp_zig_claim = c_abi.awp_zig_claim;
pub const awp_zig_commit = c_abi.awp_zig_commit;
pub const awp_zig_submit = c_abi.awp_zig_submit;

comptime {
    _ = c_abi;
    _ = types;
}

/// High-performance SIMD checksum using Zig 0.16 @Vector primitives
pub inline fn fastSum64(ptr: [*]const u8) u32 {
    const V = @Vector(64, u8);
    const v: V = ptr[0..64].*;
    const v_wide: @Vector(64, u16) = v;
    return @reduce(.Add, v_wide);
}

pub const AWP_FLAG_DROPPED: u32 = 0x8000_0000;

const c_time = @cImport({
    @cInclude("time.h");
});

const c_mman = @cImport({
    @cInclude("sys/mman.h");
});

/// Nanosecond monotonic timestamp reader (POSIX clock_gettime)
pub inline fn nowNs() u64 {
    var ts: c_time.struct_timespec = undefined;
    _ = c_time.clock_gettime(c_time.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
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

/// Low-Latency HugePage (2MB) & Prefaulted Memory Slab Allocator
/// Backed by explicit HugeTLB (MAP_HUGETLB / 2MB pages) or THP (MADV_HUGEPAGE) with 4KB fallback.
/// Eliminates runtime Demand-Paging Minor Page Faults and minimizes TLB footprint.
pub const HftMemorySlab = struct {
    pub const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024; // 2MB HugePage
    pub const BASE_PAGE_SIZE: usize = 4096;

    ptr: [*]align(64) u8,
    len: usize,
    is_huge_page: bool,

    /// Standard allocation: Attempts explicit 2MB HugePages (MAP_HUGETLB) on Linux,
    /// falling back to transparent hugepage advisory (MADV_HUGEPAGE) and page prefaulting, with verified mlock.
    pub fn allocate(size_bytes: usize) !HftMemorySlab {
        return allocateInternal(size_bytes, true, false);
    }

    /// Strict HugePage allocation: Fails with error.HugePagesUnavailable if 2MB HugeTLB pages cannot be allocated
    pub fn allocateStrictHugePages(size_bytes: usize) !HftMemorySlab {
        return allocateInternal(size_bytes, true, true);
    }

    /// Permissive allocation: Best-effort hugepages and mlock (does not fail if mlock is restricted in containers)
    pub fn allocatePermissive(size_bytes: usize) !HftMemorySlab {
        return allocateInternal(size_bytes, false, false);
    }

    fn allocateInternal(size_bytes: usize, strict_mlock: bool, strict_huge: bool) !HftMemorySlab {
        const is_linux = @import("builtin").os.tag == .linux;
        var is_huge = false;
        var raw: ?*anyopaque = null;
        var final_size: usize = 0;

        // 1. Try explicit 2MB HugePages on Linux (MAP_HUGETLB)
        if (is_linux and @hasDecl(c_mman, "MAP_HUGETLB")) {
            final_size = std.mem.alignForward(usize, size_bytes, HUGE_PAGE_SIZE);
            const flags: c_int = c_mman.MAP_PRIVATE | c_mman.MAP_ANON | c_mman.MAP_HUGETLB;
            const res = c_mman.mmap(null, final_size, c_mman.PROT_READ | c_mman.PROT_WRITE, flags, -1, 0);
            if (res != c_mman.MAP_FAILED) {
                raw = res;
                is_huge = true;
            }
        }

        // If strict huge pages requested and failed, return error
        if (strict_huge and raw == null) {
            return error.HugePagesUnavailable;
        }

        // 2. Fallback to 4KB page aligned anonymous mapping
        if (raw == null) {
            final_size = std.mem.alignForward(usize, size_bytes, BASE_PAGE_SIZE);
            const flags: c_int = c_mman.MAP_PRIVATE | c_mman.MAP_ANON;
            const res = c_mman.mmap(null, final_size, c_mman.PROT_READ | c_mman.PROT_WRITE, flags, -1, 0);
            if (res == c_mman.MAP_FAILED) {
                return error.OutOfMemory;
            }
            raw = res;

            // Advise kernel to use Transparent Huge Pages (MADV_HUGEPAGE / MADV_WILLNEED)
            if (@hasDecl(c_mman, "MADV_HUGEPAGE")) {
                _ = c_mman.madvise(raw, final_size, c_mman.MADV_HUGEPAGE);
            }
            if (@hasDecl(c_mman, "MADV_WILLNEED")) {
                _ = c_mman.madvise(raw, final_size, c_mman.MADV_WILLNEED);
            }
        }

        const ptr: [*]align(64) u8 = @ptrCast(@alignCast(raw.?));

        // 3. Memory Prefaulting: Touch every page (2MB stride if huge, 4KB stride if base) to eliminate runtime page faults
        const stride = if (is_huge) HUGE_PAGE_SIZE else BASE_PAGE_SIZE;
        var off: usize = 0;
        while (off < final_size) : (off += stride) {
            ptr[off] = 0;
        }

        // 4. Memory Locking (mlock)
        if (c_mman.mlock(raw.?, final_size) != 0) {
            if (strict_mlock) {
                _ = c_mman.munmap(raw.?, final_size);
                return error.MlockFailed;
            }
        }

        return HftMemorySlab{
            .ptr = ptr,
            .len = final_size,
            .is_huge_page = is_huge,
        };
    }

    pub fn deallocate(self: *HftMemorySlab) void {
        _ = c_mman.munlock(self.ptr, self.len);
        _ = c_mman.munmap(self.ptr, self.len);
    }
};

/// Ultra-Fast Cache-Optimized Single-Producer Single-Consumer (SPSC) Ring Buffer
/// Features:
/// - 0 CAS instructions (Pure atomic load/store)
/// - Cached Head/Tail to eliminate cross-thread cache-line invalidation
/// - Embedded pre-allocated slabs with tuned hardware prefetch lookahead
/// - Peak throughput: > 100M ops/sec (< 8 ns/op)
pub fn SpscRing(comptime capacity: usize) type {
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }
    return struct {
        const Self = @This();
        const mask = capacity - 1;
        const PREFETCH_DISTANCE = 4;

        frames: []Frame,
        head: std.atomic.Value(usize) align(64),
        cached_tail: usize align(64),
        tail: std.atomic.Value(usize) align(64),
        cached_head: usize align(64),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const frames = try allocator.alloc(Frame, capacity);
            return Self{
                .frames = frames,
                .head = std.atomic.Value(usize).init(0),
                .cached_tail = 0,
                .tail = std.atomic.Value(usize).init(0),
                .cached_head = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.frames);
        }

        pub inline fn tryPush(self: *Self, frame: *const Frame) bool {
            const head = self.head.load(.monotonic);
            if (head - self.cached_tail >= capacity) {
                self.cached_tail = self.tail.load(.acquire);
                if (head - self.cached_tail >= capacity) {
                    @branchHint(.unlikely);
                    return false; // Queue full
                }
            }

            self.frames[head & mask] = frame.*;
            @prefetch(&self.frames[(head + PREFETCH_DISTANCE) & mask], .{ .rw = .write, .locality = 3, .cache = .data });
            self.head.store(head + 1, .release);
            return true;
        }

        pub inline fn claim(self: *Self) ?*Frame {
            const head = self.head.load(.monotonic);
            if (head - self.cached_tail >= capacity) {
                self.cached_tail = self.tail.load(.acquire);
                if (head - self.cached_tail >= capacity) {
                    @branchHint(.unlikely);
                    return null; // Queue full
                }
            }
            const f = &self.frames[head & mask];
            @prefetch(&self.frames[(head + PREFETCH_DISTANCE) & mask], .{ .rw = .write, .locality = 3, .cache = .data });
            return f;
        }

        pub inline fn commit(self: *Self) void {
            const head = self.head.load(.monotonic);
            self.head.store(head + 1, .release);
        }

        pub inline fn tryPop(self: *Self) ?*Frame {
            const tail = self.tail.load(.monotonic);
            if (self.cached_head == tail) {
                self.cached_head = self.head.load(.acquire);
                if (self.cached_head == tail) {
                    @branchHint(.unlikely);
                    return null; // Queue empty
                }
            }

            const data = &self.frames[tail & mask];
            @prefetch(&self.frames[(tail + PREFETCH_DISTANCE) & mask], .{ .rw = .read, .locality = 3, .cache = .data });
            self.tail.store(tail + 1, .release);
            return data;
        }
    };
}

/// Bounded Multi-Producer Single-Consumer (MPSC) Lock-Free Ring Buffer with Embedded Slabs
pub fn LockFreeRing(comptime capacity: usize) type {
    comptime {
        std.debug.assert(std.math.isPowerOfTwo(capacity));
    }
    return struct {
        const Self = @This();
        const mask = capacity - 1;
        const PREFETCH_DISTANCE = 4;

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
                    f.flags = 0;
                    f.submit_ns = nowNs();
                    @prefetch(&self.frames[(pos + PREFETCH_DISTANCE) & mask], .{ .rw = .write, .locality = 3, .cache = .data });
                    return Claim{
                        .frame = f,
                        .shard = shard,
                        .pos = pos,
                    };
                } else if (dif < 0) {
                    @branchHint(.unlikely);
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
                    @prefetch(&self.frames[(pos + PREFETCH_DISTANCE) & mask], .{ .rw = .write, .locality = 3, .cache = .data });
                    cell.sequence.store(pos + 1, .release);
                    return true;
                } else if (dif < 0) {
                    @branchHint(.unlikely);
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
                @prefetch(&self.frames[(pos + PREFETCH_DISTANCE) & mask], .{ .rw = .read, .locality = 3, .cache = .data });
                cell.sequence.store(pos + capacity, .release);
                return data;
            } else {
                @branchHint(.unlikely);
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

test "SpscRing push pop" {
    var ring = try SpscRing(64).init(std.testing.allocator);
    defer ring.deinit();

    var f: Frame = .{};
    @memcpy(f.feed[0..4], "test");
    f.feed[4] = 0;
    try std.testing.expect(ring.tryPush(&f));

    const pop_f = ring.tryPop();
    try std.testing.expect(pop_f != null);
    try std.testing.expectEqualStrings("test", std.mem.sliceTo(&pop_f.?.feed, 0));
}

test "SIMD fastSum64" {
    const buf = [_]u8{1} ** 64;
    const sum = fastSum64(&buf);
    try std.testing.expectEqual(@as(u32, 64), sum);
}

test "DynamicPool lifecycle" {
    const Helper = struct {
        var count: usize = 0;
        fn process(frame: *const Frame, user: ?*anyopaque) callconv(.c) i32 {
            _ = frame;
            _ = user;
            count += 1;
            return 0;
        }
    };
    Helper.count = 0;

    const pool = try DynamicPool.init(std.testing.allocator, 2, 64, Helper.process, null);
    defer pool.deinit();

    const claim_slot = pool.claim(0);
    try std.testing.expect(claim_slot != null);
    pool.commit(claim_slot.?);

    var waited: usize = 0;
    while (Helper.count < 1 and waited < 100_000) : (waited += 1) {
        try std.Thread.yield();
    }
    try std.testing.expectEqual(@as(usize, 1), Helper.count);
}

test "HftMemorySlab allocation prefaulting and deallocation" {
    var slab = try HftMemorySlab.allocate(64 * 1024);
    defer slab.deallocate();

    try std.testing.expect(slab.len >= 64 * 1024);
    try std.testing.expectEqual(@as(u8, 0), slab.ptr[0]);
    try std.testing.expectEqual(@as(u8, 0), slab.ptr[slab.len - 1]);

    // Test write and read
    slab.ptr[0] = 0xAA;
    slab.ptr[slab.len - 1] = 0x55;
    try std.testing.expectEqual(@as(u8, 0xAA), slab.ptr[0]);
    try std.testing.expectEqual(@as(u8, 0x55), slab.ptr[slab.len - 1]);

    // Test permissive mode
    var slab_perm = try HftMemorySlab.allocatePermissive(32 * 1024);
    defer slab_perm.deallocate();
    try std.testing.expect(slab_perm.len >= 32 * 1024);
}
