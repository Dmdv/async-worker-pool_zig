//! Low-level unsafe C FFI definitions for Zig libawp_zig engine.

use std::os::raw::{c_char, c_int, c_void};

pub const AWP_FEED_MAX: usize = 64;
pub const AWP_SYMBOL_MAX: usize = 64;
pub const AWP_PAYLOAD_MAX: usize = 4096;
pub const AWP_FLAG_DROPPED: u32 = 0x8000_0000;

#[repr(C)]
pub struct AwpFrame {
    pub feed: [u8; AWP_FEED_MAX + 1],
    pub symbol: [u8; AWP_SYMBOL_MAX + 1],
    pub payload: [u8; AWP_PAYLOAD_MAX],
    pub payload_len: usize,
    pub seq: u64,
    pub submit_ns: u64,
    pub shard: u32,
    pub flags: u32,
}

#[repr(C)]
pub struct AwpClaim {
    pub frame: *mut AwpFrame,
    pub shard: u32,
    pub pos: usize,
}

pub type AwpProcessFn = unsafe extern "C" fn(frame: *const AwpFrame, user: *mut c_void) -> c_int;

extern "C" {
    pub fn awp_zig_pool_create(
        workers: u32,
        queue_capacity: u32,
        callback: Option<AwpProcessFn>,
        user: *mut c_void,
        out_pool: *mut *mut c_void,
    ) -> c_int;

    pub fn awp_zig_pool_destroy(pool: *mut c_void);

    pub fn awp_zig_claim(
        pool: *mut c_void,
        shard: u32,
        out_claim: *mut AwpClaim,
    ) -> c_int;

    pub fn awp_zig_commit(
        pool: *mut c_void,
        claim: *const AwpClaim,
    ) -> c_int;

    pub fn awp_zig_submit(
        pool: *mut c_void,
        feed: *const c_char,
        symbol: *const c_char,
        payload: *const c_void,
        payload_len: usize,
        flags: u32,
    ) -> c_int;
}
