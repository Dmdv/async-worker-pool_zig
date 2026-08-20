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

/// 64-Byte Cache-Line Aligned Financial Top-of-Book Update (Zero-Copy POD)
#[repr(C, align(64))]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BookUpdate64 {
    pub timestamp_ns: u64,
    pub seq: u64,
    pub symbol_id: u32,
    pub flags: u32,
    pub bid_price: f64,
    pub bid_qty: f64,
    pub ask_price: f64,
    pub ask_qty: f64,
    pub _reserved: [u8; 8],
}

/// 64-Byte Cache-Line Aligned Financial Trade Event (Zero-Copy POD)
#[repr(C, align(64))]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Trade64 {
    pub timestamp_ns: u64,
    pub trade_id: u64,
    pub price: f64,
    pub qty: f64,
    pub symbol_id: u32,
    pub side: u32,
    pub flags: u32,
    pub taker_order_id: u32,
    pub _reserved: [u8; 16],
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

const _: () = {
    assert!(std::mem::size_of::<BookUpdate64>() == 64);
    assert!(std::mem::align_of::<BookUpdate64>() == 64);
    assert!(std::mem::size_of::<Trade64>() == 64);
    assert!(std::mem::align_of::<Trade64>() == 64);
};
