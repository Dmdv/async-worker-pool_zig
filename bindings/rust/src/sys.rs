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

/// 64-Byte Cache-Line Aligned Financial Order Execution Signal (Zero-Copy POD)
#[repr(C, align(64))]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OrderSignal64 {
    pub timestamp_ns: u64,
    pub ingress_ts_ns: u64,
    pub order_id: u64,
    pub price: f64,
    pub qty: f64,
    pub symbol_id: u32,
    pub side: u32,
    pub action: u32,
    pub flags: u32,
    pub _reserved: [u8; 8],
}

#[repr(C)]
pub struct AwpClaim {
    pub frame: *mut AwpFrame,
    pub shard: u32,
    pub pos: usize,
}

pub type AwpProcessFn = unsafe extern "C" fn(frame: *const AwpFrame, user: *mut c_void) -> c_int;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketDescriptor {
    pub timestamp_ns: u64,
    pub offset: u32,
    pub len: u32,
}

extern "C" {
    pub fn awp_zig_pool_create(
        workers: u32,
        queue_capacity: u32,
        callback: Option<AwpProcessFn>,
        user: *mut c_void,
        out_pool: *mut *mut c_void,
    ) -> c_int;

    pub fn awp_zig_pool_destroy(pool: *mut c_void);

    pub fn awp_zig_claim(pool: *mut c_void, shard: u32, out_claim: *mut AwpClaim) -> c_int;

    pub fn awp_zig_commit(pool: *mut c_void, claim: *const AwpClaim) -> c_int;

    pub fn awp_zig_submit(
        pool: *mut c_void,
        feed: *const c_char,
        symbol: *const c_char,
        payload: *const c_void,
        payload_len: usize,
        flags: u32,
    ) -> c_int;

    pub fn awp_zig_bip_create(capacity: usize, out_bip: *mut *mut c_void) -> c_int;
    pub fn awp_zig_bip_destroy(bip: *mut c_void);
    pub fn awp_zig_bip_reserve(bip: *mut c_void, size: usize, out_ptr: *mut *mut u8) -> c_int;
    pub fn awp_zig_bip_commit(bip: *mut c_void, size: usize) -> c_int;
    pub fn awp_zig_bip_peek(
        bip: *mut c_void,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn awp_zig_bip_consume(bip: *mut c_void, size: usize) -> c_int;

    pub fn awp_zig_bipring_create(
        buffer_capacity: usize,
        desc_capacity: usize,
        out_ring: *mut *mut c_void,
    ) -> c_int;
    pub fn awp_zig_bipring_destroy(ring: *mut c_void);
    pub fn awp_zig_bipring_push(
        ring: *mut c_void,
        payload: *const u8,
        len: usize,
        timestamp_ns: u64,
    ) -> c_int;
    pub fn awp_zig_bipring_pop(
        ring: *mut c_void,
        out_payload: *mut *const u8,
        out_len: *mut usize,
        out_desc: *mut PacketDescriptor,
    ) -> c_int;
    pub fn awp_zig_bipring_release(ring: *mut c_void, desc: *const PacketDescriptor);

    pub fn awp_zig_reactor_create(out_reactor: *mut *mut c_void) -> c_int;
    pub fn awp_zig_reactor_destroy(reactor: *mut c_void);
    pub fn awp_zig_reactor_process_tick(
        reactor: *mut c_void,
        update: *const BookUpdate64,
        out_signal: *mut OrderSignal64,
    ) -> c_int;
    pub fn awp_zig_reactor_bind_risk_ring(reactor: *mut c_void, ring: *mut c_void) -> c_int;
    pub fn awp_zig_reactor_bind_audit_ring(reactor: *mut c_void, ring: *mut c_void) -> c_int;
    pub fn awp_zig_reactor_bind_telemetry_ring(reactor: *mut c_void, ring: *mut c_void) -> c_int;
    pub fn awp_zig_reactor_get_overruns(reactor: *mut c_void) -> u64;

    pub fn awp_zig_offpath_create(capacity: usize, out_offpath: *mut *mut c_void) -> c_int;
    pub fn awp_zig_offpath_start(offpath: *mut c_void) -> c_int;
    pub fn awp_zig_offpath_stop(offpath: *mut c_void);
    pub fn awp_zig_offpath_destroy(offpath: *mut c_void);
    pub fn awp_zig_offpath_get_risk_ring(offpath: *mut c_void) -> *mut c_void;
    pub fn awp_zig_offpath_get_audit_ring(offpath: *mut c_void) -> *mut c_void;
    pub fn awp_zig_offpath_get_telemetry_ring(offpath: *mut c_void) -> *mut c_void;
    pub fn awp_zig_offpath_get_processed(
        offpath: *mut c_void,
        out_risk: *mut u64,
        out_audit: *mut u64,
        out_telemetry: *mut u64,
    );
}

const _: () = {
    assert!(std::mem::size_of::<BookUpdate64>() == 64);
    assert!(std::mem::align_of::<BookUpdate64>() == 64);
    assert!(std::mem::size_of::<Trade64>() == 64);
    assert!(std::mem::align_of::<Trade64>() == 64);
    assert!(std::mem::size_of::<OrderSignal64>() == 64);
    assert!(std::mem::align_of::<OrderSignal64>() == 64);
    assert!(std::mem::size_of::<PacketDescriptor>() == 16);
    assert!(std::mem::align_of::<PacketDescriptor>() == 8);

    assert!(core::mem::offset_of!(OrderSignal64, timestamp_ns) == 0);
    assert!(core::mem::offset_of!(OrderSignal64, ingress_ts_ns) == 8);
    assert!(core::mem::offset_of!(OrderSignal64, order_id) == 16);
    assert!(core::mem::offset_of!(OrderSignal64, price) == 24);
    assert!(core::mem::offset_of!(OrderSignal64, qty) == 32);
    assert!(core::mem::offset_of!(OrderSignal64, symbol_id) == 40);
    assert!(core::mem::offset_of!(OrderSignal64, side) == 44);
    assert!(core::mem::offset_of!(OrderSignal64, action) == 48);
    assert!(core::mem::offset_of!(OrderSignal64, flags) == 52);
    assert!(core::mem::offset_of!(OrderSignal64, _reserved) == 56);
};
