const std = @import("std");

pub const AWP_FEED_MAX: usize = 64;
pub const AWP_SYMBOL_MAX: usize = 64;
pub const AWP_PAYLOAD_MAX: usize = 4096;

pub const Frame = extern struct {
    feed: [AWP_FEED_MAX + 1]u8 = [_]u8{0} ** (AWP_FEED_MAX + 1),
    symbol: [AWP_SYMBOL_MAX + 1]u8 = [_]u8{0} ** (AWP_SYMBOL_MAX + 1),
    payload: [AWP_PAYLOAD_MAX]u8 = [_]u8{0} ** AWP_PAYLOAD_MAX,
    payload_len: usize = 0,
    seq: u64 = 0,
    submit_ns: u64 = 0,
    shard: u32 = 0,
    flags: u32 = 0,
};

pub const Claim = extern struct {
    frame: *Frame,
    shard: u32,
    pos: usize,
};

comptime {
    std.debug.assert(@offsetOf(Frame, "feed") == 0);
    std.debug.assert(@offsetOf(Frame, "symbol") == 65);
    std.debug.assert(@offsetOf(Frame, "payload") == 130);
    std.debug.assert(@offsetOf(Frame, "payload_len") == 4232);
    std.debug.assert(@offsetOf(Frame, "seq") == 4240);
    std.debug.assert(@offsetOf(Frame, "submit_ns") == 4248);
    std.debug.assert(@offsetOf(Frame, "shard") == 4256);
    std.debug.assert(@offsetOf(Frame, "flags") == 4260);
    std.debug.assert(@sizeOf(Frame) == 4264);
}
