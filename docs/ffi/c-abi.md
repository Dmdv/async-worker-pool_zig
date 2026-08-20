# C ABI Specification

AWP exports a zero-overhead, C11-compatible Foreign Function Interface (FFI). All data structures follow the standard C binary layout (`extern struct`) with 64-byte cacheline alignment.

---

## 📋 Standard Error Return Codes

| Code | POSIX Equivalent | Description |
| :--- | :--- | :--- |
| **`0`** | `0` | Success |
| **`-22`** | `-EINVAL` | Invalid argument (null pointer, non-power-of-two capacity, unreserved commit) |
| **`-12`** | `-ENOMEM` | Out of memory |
| **`-11`** | `-EAGAIN` | Ring queue is Full (push) or Empty (pop) |

---

## 🛠 Exported C ABI Functions

### 1. Multi-Threaded Worker Pool (`awp_zig_pool_*`)
```c
int awp_zig_pool_create(size_t num_workers, size_t queue_capacity, awp_zig_worker_fn callback, void *user, void **out_pool);
void awp_zig_pool_destroy(void *pool_ptr);
int awp_zig_pool_submit(void *pool_ptr, const uint8_t *data, size_t len, uint32_t flags);
int awp_zig_pool_claim(void *pool_ptr, uint8_t **out_slot, size_t *out_capacity);
int awp_zig_pool_commit(void *pool_ptr, uint8_t *slot, size_t len, uint32_t flags);
```

### 2. 64-Byte POD Cacheline SPSC Ring (`awp_zig_spsc64_*`)
```c
int awp_zig_spsc64_create(size_t capacity, void **out_ring);
void awp_zig_spsc64_destroy(void *ring_ptr);
int awp_zig_spsc64_push(void *ring_ptr, const void *book_update_64);
int awp_zig_spsc64_pop(void *ring_ptr, void *out_book_update_64);
int awp_zig_spsc64_claim(void *ring_ptr, void **out_slot);
int awp_zig_spsc64_commit(void *ring_ptr);
```

### 3. Variable-Length Zero-Copy BipRing (`awp_zig_bipring_*`)
```c
typedef struct {
    uint64_t timestamp_ns;
    uint32_t offset;
    uint32_t len;
} awp_zig_packet_desc_t;

int awp_zig_bipring_create(size_t buffer_capacity, size_t desc_capacity, void **out_ring);
void awp_zig_bipring_destroy(void *ring_ptr);
int awp_zig_bipring_push(void *ring_ptr, const uint8_t *payload, size_t len, uint64_t timestamp_ns);
int awp_zig_bipring_pop(void *ring_ptr, const uint8_t **out_payload, size_t *out_len, awp_zig_packet_desc_t *out_desc);
void awp_zig_bipring_release(void *ring_ptr, const awp_zig_packet_desc_t *desc);
```
