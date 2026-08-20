//! # awp-zig-rs: Safe & High-Performance Rust FFI Bindings for Zig 0.16 Engine
//!
//! Exposes the ultra-low-latency Zig 0.16 async worker pool to Rust applications with:
//! - Sub-microsecond dispatch latencies (667 ns median)
//! - Multi-million ops/sec throughput
//! - Zero-Copy Claim & Commit API
//! - Zero dynamic memory allocations on the hot path
//! - Safe RAII lifecycle management

pub mod error;
pub mod sys;

pub use error::AwpError;
pub use sys::{
    AwpClaim, AwpFrame, BookUpdate64, OrderSignal64, PacketDescriptor, Trade64, AWP_FEED_MAX,
    AWP_FLAG_DROPPED, AWP_PAYLOAD_MAX, AWP_SYMBOL_MAX,
};

use std::os::raw::{c_int, c_void};
use std::ptr;

#[inline]
fn copy_str_to_fixed_buf(s: &str, buf: &mut [u8]) -> Result<(), AwpError> {
    let bytes = s.as_bytes();
    if bytes.len() >= buf.len() {
        return Err(AwpError::TooBig);
    }
    buf[..bytes.len()].copy_from_slice(bytes);
    buf[bytes.len()] = 0;
    Ok(())
}

/// Read-only view of a frame delivered to a worker callback.
pub struct FrameView<'a> {
    raw: &'a sys::AwpFrame,
}

impl<'a> FrameView<'a> {
    /// Borrow the payload buffer slice.
    #[inline]
    pub fn payload(&self) -> &[u8] {
        &self.raw.payload[..self.raw.payload_len]
    }

    /// Monotonic sequence number.
    #[inline]
    pub fn seq(&self) -> u64 {
        self.raw.seq
    }

    /// Shard / worker index.
    #[inline]
    pub fn shard(&self) -> u32 {
        self.raw.shard
    }

    /// Monotonic submission timestamp in nanoseconds.
    #[inline]
    pub fn submit_ns(&self) -> u64 {
        self.raw.submit_ns
    }

    /// Frame flags.
    #[inline]
    pub fn flags(&self) -> u32 {
        self.raw.flags
    }

    /// Feed label as a string slice.
    #[inline]
    pub fn feed(&self) -> &str {
        let nul_pos = self
            .raw
            .feed
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(self.raw.feed.len());
        std::str::from_utf8(&self.raw.feed[..nul_pos]).unwrap_or("")
    }

    /// Symbol label as a string slice.
    #[inline]
    pub fn symbol(&self) -> &str {
        let nul_pos = self
            .raw
            .symbol
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(self.raw.symbol.len());
        std::str::from_utf8(&self.raw.symbol[..nul_pos]).unwrap_or("")
    }

    /// Zero-copy read of a plain-old-data (POD) struct value from payload.
    #[inline]
    pub fn payload_as<T: Copy>(&self) -> Option<T> {
        if self.raw.payload_len < std::mem::size_of::<T>() {
            return None;
        }
        unsafe {
            let ptr = self.raw.payload.as_ptr() as *const T;
            Some(ptr::read_unaligned(ptr))
        }
    }
}

/// Token representing a claimed slot in the worker ring for Zero-Copy in-place writing.
pub struct ClaimGuard<'a> {
    pool: &'a AsyncWorkerPool,
    claim: sys::AwpClaim,
    committed: bool,
}

impl<'a> ClaimGuard<'a> {
    /// Direct mutable access to payload buffer for zero-copy writes.
    #[inline]
    pub fn payload_mut(&mut self) -> &mut [u8] {
        unsafe {
            let f = &mut *self.claim.frame;
            &mut f.payload[..]
        }
    }

    /// Set feed label string.
    pub fn set_feed(&mut self, feed: &str) -> Result<(), AwpError> {
        let f = unsafe { &mut *self.claim.frame };
        copy_str_to_fixed_buf(feed, &mut f.feed)
    }

    /// Set symbol label string.
    pub fn set_symbol(&mut self, symbol: &str) -> Result<(), AwpError> {
        let f = unsafe { &mut *self.claim.frame };
        copy_str_to_fixed_buf(symbol, &mut f.symbol)
    }

    /// Set payload length.
    #[inline]
    pub fn set_payload_len(&mut self, len: usize) {
        unsafe {
            let f = &mut *self.claim.frame;
            f.payload_len = len.min(sys::AWP_PAYLOAD_MAX);
        }
    }

    /// Set custom user/system flags.
    #[inline]
    pub fn set_flags(&mut self, flags: u32) {
        unsafe {
            let f = &mut *self.claim.frame;
            f.flags = flags;
        }
    }

    /// Direct zero-copy serialization of POD types into the payload buffer.
    #[inline]
    pub fn write_struct<T: Copy>(&mut self, value: &T) -> Result<(), AwpError> {
        let size = std::mem::size_of::<T>();
        if size > sys::AWP_PAYLOAD_MAX {
            return Err(AwpError::TooBig);
        }
        unsafe {
            let f = &mut *self.claim.frame;
            let dest_ptr = f.payload.as_mut_ptr() as *mut T;
            ptr::write_unaligned(dest_ptr, *value);
            f.payload_len = size;
        }
        Ok(())
    }

    /// Explicitly abort/discard the claim without committing user work.
    #[inline]
    pub fn abort(self) {
        // Drop implementation publishes the tombstone frame
    }

    /// Commit the frame to the worker queue.
    pub fn commit(mut self) -> Result<(), AwpError> {
        let rc = unsafe { sys::awp_zig_commit(self.pool.handle, &self.claim) };
        if rc != 0 {
            return Err(AwpError::from(rc));
        }
        self.committed = true;
        Ok(())
    }
}

impl<'a> Drop for ClaimGuard<'a> {
    fn drop(&mut self) {
        if !self.committed {
            // Mark dropped/abandoned frame
            unsafe {
                let f = &mut *self.claim.frame;
                f.flags = sys::AWP_FLAG_DROPPED;
                f.payload_len = 0;
                f.feed[0] = 0;
                f.symbol[0] = 0;
                let _ = sys::awp_zig_commit(self.pool.handle, &self.claim);
            }
            self.committed = true;
        }
    }
}

struct ContextClosure {
    callback: Box<dyn Fn(&FrameView) -> i32 + Send + Sync + 'static>,
}

unsafe extern "C" fn trampoline(frame: *const sys::AwpFrame, user: *mut c_void) -> c_int {
    let ctx = &*(user as *const ContextClosure);
    let view = FrameView { raw: &*frame };
    (ctx.callback)(&view) as c_int
}

/// Safe Rust wrapper over Zig `DynamicPool`.
pub struct AsyncWorkerPool {
    handle: *mut c_void,
    _ctx: Box<ContextClosure>,
}

unsafe impl Send for AsyncWorkerPool {}
unsafe impl Sync for AsyncWorkerPool {}

impl AsyncWorkerPool {
    /// Create a new asynchronous worker pool.
    pub fn new<F>(workers: u32, queue_capacity: u32, callback: F) -> Result<Self, AwpError>
    where
        F: Fn(&FrameView) -> i32 + Send + Sync + 'static,
    {
        let mut handle: *mut c_void = ptr::null_mut();
        let ctx = Box::new(ContextClosure {
            callback: Box::new(callback),
        });
        let user_data = &*ctx as *const ContextClosure as *mut c_void;

        let rc = unsafe {
            sys::awp_zig_pool_create(
                workers,
                queue_capacity,
                Some(trampoline),
                user_data,
                &mut handle,
            )
        };

        if rc != 0 {
            return Err(AwpError::from(rc));
        }

        Ok(Self { handle, _ctx: ctx })
    }

    /// High-level submission helper with automatic string labeling and payload copy.
    pub fn submit(
        &self,
        feed: &str,
        symbol: &str,
        payload: &[u8],
        flags: u32,
    ) -> Result<(), AwpError> {
        let mut hash: u64 = 0xcbf29ce484222325;
        for b in feed.as_bytes() {
            hash = (hash ^ (*b as u64)).wrapping_mul(0x100000001b3);
        }
        for b in symbol.as_bytes() {
            hash = (hash ^ (*b as u64)).wrapping_mul(0x100000001b3);
        }

        let shard = (hash & 0xFFFFFFFF) as u32;

        let mut guard = loop {
            match self.claim(shard) {
                Ok(g) => break g,
                Err(AwpError::QueueFull) => std::thread::yield_now(),
                Err(err) => return Err(err),
            }
        };

        guard.set_feed(feed)?;
        guard.set_symbol(symbol)?;
        guard.set_flags(flags);

        let buf = guard.payload_mut();
        let len = payload.len().min(sys::AWP_PAYLOAD_MAX);
        buf[..len].copy_from_slice(&payload[..len]);
        guard.set_payload_len(len);

        guard.commit()?;
        Ok(())
    }

    /// Claim an enqueue slot for Zero-Copy in-place writing directly in the ring slab.
    pub fn claim(&self, shard: u32) -> Result<ClaimGuard<'_>, AwpError> {
        let mut claim: sys::AwpClaim = unsafe { std::mem::zeroed() };
        let rc = unsafe { sys::awp_zig_claim(self.handle, shard, &mut claim) };
        if rc == 0 {
            Ok(ClaimGuard {
                pool: self,
                claim,
                committed: false,
            })
        } else {
            Err(AwpError::from(rc))
        }
    }
}

impl Drop for AsyncWorkerPool {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                sys::awp_zig_pool_destroy(self.handle);
            }
            self.handle = ptr::null_mut();
        }
    }
}

/// High-Performance Zero-Copy Variable-Length Bipartite Ring Buffer
pub struct BipBuffer {
    handle: *mut c_void,
}

unsafe impl Send for BipBuffer {}

impl BipBuffer {
    /// Create a new BipBuffer with specified byte capacity (must be power of two >= 64).
    pub fn new(capacity: usize) -> Result<Self, AwpError> {
        let mut handle = ptr::null_mut();
        let rc = unsafe { sys::awp_zig_bip_create(capacity, &mut handle) };
        if rc == 0 {
            Ok(Self { handle })
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Zero-Copy Reserve: request a contiguous mutable slice of exactly `size` bytes.
    pub fn reserve(&mut self, size: usize) -> Option<&mut [u8]> {
        let mut out_ptr = ptr::null_mut();
        let rc = unsafe { sys::awp_zig_bip_reserve(self.handle, size, &mut out_ptr) };
        if rc == 0 && !out_ptr.is_null() {
            Some(unsafe { std::slice::from_raw_parts_mut(out_ptr, size) })
        } else {
            None
        }
    }

    /// Commit previously reserved bytes.
    ///
    /// # Safety
    /// Caller must ensure `size` does not exceed the length of the slice returned by the last successful `reserve()`.
    pub unsafe fn commit(&mut self, size: usize) -> Result<(), AwpError> {
        let rc = sys::awp_zig_bip_commit(self.handle, size);
        if rc == 0 {
            Ok(())
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Push contiguous data into BipBuffer (convenience copy wrapper).
    pub fn push(&mut self, data: &[u8]) -> bool {
        if let Some(buf) = self.reserve(data.len()) {
            buf.copy_from_slice(data);
            unsafe { self.commit(data.len()).is_ok() }
        } else {
            false
        }
    }

    /// Zero-Copy Peek: view the next readable contiguous slice.
    pub fn peek(&mut self) -> Option<&[u8]> {
        let mut out_ptr = ptr::null();
        let mut out_len = 0;
        let rc = unsafe { sys::awp_zig_bip_peek(self.handle, &mut out_ptr, &mut out_len) };
        if rc == 0 && !out_ptr.is_null() && out_len > 0 {
            Some(unsafe { std::slice::from_raw_parts(out_ptr, out_len) })
        } else {
            None
        }
    }

    /// Mark `size` bytes as consumed.
    ///
    /// # Safety
    /// Caller must ensure `size` does not exceed the length of the slice returned by the last successful `peek()`.
    pub unsafe fn consume(&mut self, size: usize) -> Result<(), AwpError> {
        let rc = sys::awp_zig_bip_consume(self.handle, size);
        if rc == 0 {
            Ok(())
        } else {
            Err(AwpError::from(rc))
        }
    }
}

impl Drop for BipBuffer {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                sys::awp_zig_bip_destroy(self.handle);
            }
            self.handle = ptr::null_mut();
        }
    }
}

/// A discrete packet view popped from `BipRing`.
///
/// Automatically releases its slot in `BipRing` when dropped (Zero-Copy RAII).
pub struct PacketView<'a> {
    ring: &'a mut BipRing,
    payload: &'a [u8],
    desc: sys::PacketDescriptor,
}

impl<'a> PacketView<'a> {
    #[inline]
    pub fn payload(&self) -> &[u8] {
        self.payload
    }

    #[inline]
    pub fn timestamp_ns(&self) -> u64 {
        self.desc.timestamp_ns
    }

    #[inline]
    pub fn offset(&self) -> u32 {
        self.desc.offset
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.desc.len as usize
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.desc.len == 0
    }
}

impl<'a> Drop for PacketView<'a> {
    fn drop(&mut self) {
        unsafe { sys::awp_zig_bipring_release(self.ring.handle, &self.desc) };
    }
}

/// High-Performance Zero-Copy Variable-Length Packet Ring Buffer
pub struct BipRing {
    handle: *mut c_void,
}

unsafe impl Send for BipRing {}

impl BipRing {
    /// Create a new BipRing with specified buffer byte capacity and descriptor queue capacity (powers of two).
    pub fn new(buffer_capacity: usize, desc_capacity: usize) -> Result<Self, AwpError> {
        let mut handle = ptr::null_mut();
        let rc =
            unsafe { sys::awp_zig_bipring_create(buffer_capacity, desc_capacity, &mut handle) };
        if rc == 0 {
            Ok(Self { handle })
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Push a variable-length packet payload with an ingress hardware timestamp.
    /// Returns `true` if enqueued successfully, `false` if queue is full.
    pub fn push_packet(&mut self, payload: &[u8], timestamp_ns: u64) -> bool {
        let rc = unsafe {
            sys::awp_zig_bipring_push(self.handle, payload.as_ptr(), payload.len(), timestamp_ns)
        };
        rc == 0
    }

    /// Pop the next variable-length packet payload with zero copies.
    pub fn pop_packet(&mut self) -> Option<PacketView<'_>> {
        let mut out_ptr = ptr::null();
        let mut out_len = 0;
        let mut desc: sys::PacketDescriptor = unsafe { std::mem::zeroed() };
        let rc =
            unsafe { sys::awp_zig_bipring_pop(self.handle, &mut out_ptr, &mut out_len, &mut desc) };
        if rc == 0 && !out_ptr.is_null() && out_len > 0 {
            let payload = unsafe { std::slice::from_raw_parts(out_ptr, out_len) };
            Some(PacketView {
                ring: self,
                payload,
                desc,
            })
        } else {
            None
        }
    }
}

impl Drop for BipRing {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                sys::awp_zig_bipring_destroy(self.handle);
            }
            self.handle = ptr::null_mut();
        }
    }
}

/// High-performance Single-Threaded Trading Reactor (Critical Fast-Path)
pub struct TradingReactor<'a> {
    handle: *mut c_void,
    offpath: Option<&'a mut OffPathPipeline>,
}

/// Safety: TradingReactor owns its underlying C pointer uniquely and is strictly `!Sync`.
/// Moving across threads is safe before starting the execution loop, but in production
/// HFT pipelines it is designed to be initialized and executed on a dedicated pinned P-Core thread.
unsafe impl<'a> Send for TradingReactor<'a> {}

impl<'a> TradingReactor<'a> {
    /// Create a new Trading Reactor core
    pub fn new() -> Result<Self, AwpError> {
        let mut handle = ptr::null_mut();
        let rc = unsafe { sys::awp_zig_reactor_create(&mut handle) };
        if rc == 0 {
            Ok(Self {
                handle,
                offpath: None,
            })
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Process incoming 64-byte top-of-book market update on the Fast-Path Core.
    /// Returns Ok(Some(OrderSignal64)) if a signal was generated, Ok(None) if evaluated cleanly with no signal, or Err(AwpError) on FFI failure.
    pub fn process_tick(&mut self, update: &BookUpdate64) -> Result<Option<OrderSignal64>, AwpError> {
        let mut signal: OrderSignal64 = unsafe { std::mem::zeroed() };
        let rc = unsafe { sys::awp_zig_reactor_process_tick(self.handle, update, &mut signal) };
        if rc == 0 {
            Ok(Some(signal))
        } else if rc == 1 {
            Ok(None)
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Process incoming 64-byte top-of-book market update on the Fast-Path Core with provided timestamp.
    /// Returns Ok(Some(OrderSignal64)) if a signal was generated, Ok(None) if evaluated cleanly with no signal, or Err(AwpError) on FFI failure.
    pub fn process_tick_with_ts(&mut self, update: &BookUpdate64, now_ns: u64) -> Result<Option<OrderSignal64>, AwpError> {
        let mut signal: OrderSignal64 = unsafe { std::mem::zeroed() };
        let rc = unsafe { sys::awp_zig_reactor_process_tick_with_ts(self.handle, update, now_ns, &mut signal) };
        if rc == 0 {
            Ok(Some(signal))
        } else if rc == 1 {
            Ok(None)
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Bind exclusively to an OffPathPipeline's worker rings for zero-mutex fan-out.
    /// Guarantees a single producer at compile time.
    pub fn bind_offpath(&mut self, offpath: &'a mut OffPathPipeline) {
        unsafe {
            let risk_ring = sys::awp_zig_offpath_get_risk_ring(offpath.handle);
            let audit_ring = sys::awp_zig_offpath_get_audit_ring(offpath.handle);
            let telem_ring = sys::awp_zig_offpath_get_telemetry_ring(offpath.handle);
            sys::awp_zig_reactor_bind_risk_ring(self.handle, risk_ring);
            sys::awp_zig_reactor_bind_audit_ring(self.handle, audit_ring);
            sys::awp_zig_reactor_bind_telemetry_ring(self.handle, telem_ring);
        }
        self.offpath = Some(offpath);
    }

    /// Query stats of the bound offpath pipeline while reactor holds the exclusive borrow.
    pub fn offpath_stats(&self) -> Option<OffPathStats> {
        self.offpath.as_ref().map(|o| o.stats())
    }

    /// Unbind offpath rings and release exclusive borrow.
    pub fn unbind_offpath(&mut self) -> Option<&'a mut OffPathPipeline> {
        unsafe {
            sys::awp_zig_reactor_bind_risk_ring(self.handle, ptr::null_mut());
            sys::awp_zig_reactor_bind_audit_ring(self.handle, ptr::null_mut());
            sys::awp_zig_reactor_bind_telemetry_ring(self.handle, ptr::null_mut());
        }
        self.offpath.take()
    }

    /// Get count of off-path ring overruns (signals dropped due to slow off-path workers).
    pub fn overruns(&self) -> u64 {
        unsafe { sys::awp_zig_reactor_get_overruns(self.handle) }
    }
}

impl<'a> Drop for TradingReactor<'a> {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                sys::awp_zig_reactor_destroy(self.handle);
            }
            self.handle = ptr::null_mut();
        }
    }
}

/// Statistics for Asynchronous Off-Path Workers
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OffPathStats {
    pub risk_processed: u64,
    pub audit_processed: u64,
    pub telemetry_processed: u64,
}

/// Asynchronous Off-Path Worker Pipeline
pub struct OffPathPipeline {
    handle: *mut c_void,
}

unsafe impl Send for OffPathPipeline {}

impl OffPathPipeline {
    /// Create a new OffPathPipeline with specified queue capacity for risk, audit, and telemetry queues.
    pub fn new(capacity: usize) -> Result<Self, AwpError> {
        let mut handle = ptr::null_mut();
        let rc = unsafe { sys::awp_zig_offpath_create(capacity, &mut handle) };
        if rc == 0 {
            Ok(Self { handle })
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Start background worker threads for Risk, Audit Logging, and Telemetry.
    pub fn start(&mut self) -> Result<(), AwpError> {
        let rc = unsafe { sys::awp_zig_offpath_start(self.handle) };
        if rc == 0 {
            Ok(())
        } else {
            Err(AwpError::from(rc))
        }
    }

    /// Stop background worker threads.
    pub fn stop(&mut self) {
        unsafe {
            sys::awp_zig_offpath_stop(self.handle);
        }
    }

    /// Get counts of processed signals across worker threads.
    pub fn stats(&self) -> OffPathStats {
        let mut risk = 0;
        let mut audit = 0;
        let mut telemetry = 0;
        unsafe {
            sys::awp_zig_offpath_get_processed(self.handle, &mut risk, &mut audit, &mut telemetry);
        }
        OffPathStats {
            risk_processed: risk,
            audit_processed: audit,
            telemetry_processed: telemetry,
        }
    }
}

impl Drop for OffPathPipeline {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe {
                sys::awp_zig_offpath_destroy(self.handle);
            }
            self.handle = ptr::null_mut();
        }
    }
}
