use awp_zig_rs::AsyncWorkerPool;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
struct TradeEvent {
    price: f64,
    qty: f64,
    order_id: u64,
}

#[test]
fn test_zig_pool_submit_and_process() {
    let processed = Arc::new(AtomicUsize::new(0));
    let proc_clone = processed.clone();

    let pool = AsyncWorkerPool::new(4, 256, move |frame| {
        assert_eq!(frame.feed(), "binance_trades");
        assert_eq!(frame.symbol(), "BTCUSDT");
        assert_eq!(frame.payload(), b"hello_from_rust_to_zig");
        proc_clone.fetch_add(1, Ordering::Release);
        0
    })
    .expect("Failed to create Zig worker pool from Rust");

    for _ in 0..100 {
        pool.submit("binance_trades", "BTCUSDT", b"hello_from_rust_to_zig", 0)
            .expect("Submit failed");
    }

    let mut waited = 0;
    while processed.load(Ordering::Acquire) < 100 && waited < 100 {
        thread::sleep(Duration::from_millis(10));
        waited += 1;
    }

    assert_eq!(processed.load(Ordering::Acquire), 100);
}

#[test]
fn test_zig_zero_copy_claim_and_typed_struct() {
    let processed = Arc::new(AtomicUsize::new(0));
    let proc_clone = processed.clone();

    let pool = AsyncWorkerPool::new(4, 256, move |frame| {
        assert_eq!(frame.feed(), "coinbase_pro");
        assert_eq!(frame.symbol(), "ETHUSDT");

        let trade = frame
            .payload_as::<TradeEvent>()
            .expect("Failed to cast payload as TradeEvent");
        assert_eq!(trade.price, 3400.50);
        assert_eq!(trade.qty, 5.25);
        assert_eq!(trade.order_id, 123456789);

        proc_clone.fetch_add(1, Ordering::Release);
        0
    })
    .expect("Failed to create Zig pool");

    for _ in 0..50 {
        let mut guard = loop {
            match pool.claim(0) {
                Ok(g) => break g,
                Err(_) => thread::yield_now(),
            }
        };

        guard.set_feed("coinbase_pro").unwrap();
        guard.set_symbol("ETHUSDT").unwrap();

        let event = TradeEvent {
            price: 3400.50,
            qty: 5.25,
            order_id: 123456789,
        };

        guard.write_struct(&event).unwrap();
        guard.commit().expect("Commit failed");
    }

    let mut waited = 0;
    while processed.load(Ordering::Acquire) < 50 && waited < 100 {
        thread::sleep(Duration::from_millis(10));
        waited += 1;
    }

    assert_eq!(processed.load(Ordering::Acquire), 50);
}

#[test]
fn test_zig_book_update_64b_pod() {
    assert_eq!(std::mem::size_of::<awp_zig_rs::BookUpdate64>(), 64);
    assert_eq!(std::mem::size_of::<awp_zig_rs::Trade64>(), 64);

    let processed = Arc::new(AtomicUsize::new(0));
    let proc_clone = processed.clone();

    let pool = AsyncWorkerPool::new(4, 256, move |frame| {
        let book = frame
            .payload_as::<awp_zig_rs::BookUpdate64>()
            .expect("Failed to cast payload as BookUpdate64");
        assert_eq!(book.seq, 1001);
        assert_eq!(book.symbol_id, 42);
        assert_eq!(book.bid_price, 50_000.50);
        assert_eq!(book.bid_qty, 1.25);
        assert_eq!(book.ask_price, 50_001.00);
        assert_eq!(book.ask_qty, 2.50);

        proc_clone.fetch_add(1, Ordering::Release);
        0
    })
    .expect("Failed to create Zig pool");

    for _ in 0..100 {
        let mut guard = loop {
            match pool.claim(0) {
                Ok(g) => break g,
                Err(_) => thread::yield_now(),
            }
        };

        let update = awp_zig_rs::BookUpdate64 {
            timestamp_ns: 1_234_567,
            seq: 1001,
            symbol_id: 42,
            flags: 2,
            bid_price: 50_000.50,
            bid_qty: 1.25,
            ask_price: 50_001.00,
            ask_qty: 2.50,
            _reserved: [0; 8],
        };

        guard.write_struct(&update).unwrap();
        guard.commit().expect("Commit failed");
    }

    let mut waited = 0;
    while processed.load(Ordering::Acquire) < 100 && waited < 100 {
        thread::sleep(Duration::from_millis(10));
        waited += 1;
    }

    assert_eq!(processed.load(Ordering::Acquire), 100);
}

#[test]
fn test_zig_bip_buffer_streaming() {
    let mut bip = awp_zig_rs::BipBuffer::new(4096).expect("Failed to create BipBuffer");

    // Push 3 variable-length payloads
    assert!(bip.push(b"small_64b_message_payload_example"));
    assert!(bip.push(&[0xAA; 512]));
    assert!(bip.push(&[0xBB; 1400])); // MTU size

    // Peek & Consume
    let slice = bip.peek().expect("Peek failed");
    assert!(slice.len() >= 33);
    assert_eq!(&slice[..33], b"small_64b_message_payload_example");
    unsafe { bip.consume(33).expect("Consume failed") };

    let slice2 = bip.peek().expect("Peek failed");
    assert_eq!(slice2[0], 0xAA);
    unsafe { bip.consume(512).expect("Consume failed") };

    let slice3 = bip.peek().expect("Peek failed");
    assert_eq!(slice3[0], 0xBB);
    unsafe { bip.consume(1400).expect("Consume failed") };

    // Test direct reserve & commit with bounds checking
    let res = bip.reserve(100).expect("Reserve 100 failed");
    res[0] = 0xCC;
    // Overcommit fails
    unsafe {
        assert!(bip.commit(101).is_err());
    }
    // Correct commit succeeds
    unsafe {
        bip.commit(100).expect("Commit 100 failed");
    }
    let slice4 = bip.peek().expect("Peek failed");
    assert_eq!(slice4[0], 0xCC);
    unsafe { bip.consume(100).expect("Consume failed") };
}

#[test]
fn test_zig_bip_ring_packet_streaming() {
    let mut ring = awp_zig_rs::BipRing::new(8192, 128).expect("Failed to create BipRing");

    let p1 = b"Ethernet header + IP header + UDP header";
    let p2 = vec![0x33u8; 1400]; // MTU payload

    assert!(ring.push_packet(p1, 1_000_001));
    assert!(ring.push_packet(&p2, 1_000_002));

    {
        let pkt1 = ring.pop_packet().expect("Pop pkt1 failed");
        assert_eq!(pkt1.payload(), p1);
        assert_eq!(pkt1.timestamp_ns(), 1_000_001);
        assert_eq!(pkt1.len(), p1.len());
    }

    {
        let pkt2 = ring.pop_packet().expect("Pop pkt2 failed");
        assert_eq!(pkt2.payload(), &p2[..]);
        assert_eq!(pkt2.timestamp_ns(), 1_000_002);
        assert_eq!(pkt2.len(), 1400);
    }

    assert!(ring.pop_packet().is_none());
}
