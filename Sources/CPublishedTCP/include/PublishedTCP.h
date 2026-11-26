#ifndef MICROPOD_PUBLISHED_TCP_H
#define MICROPOD_PUBLISHED_TCP_H

#include <stdint.h>

typedef struct mp_tcp_relay mp_tcp_relay;
typedef struct mp_tcp_listener mp_tcp_listener;

// Each sample is a handoff to a separate data owner. All three histograms
// use the same disjoint microsecond buckets as the connection stats below.
typedef struct {
    uint64_t accept_to_enqueue_us[12], enqueue_to_adopt_us[12], accept_to_adopt_us[12];
} mp_tcp_handoff_stats;

typedef struct {
    uint64_t accepted, connected, connect_errors, connect_retries, recovered, peak_active;
    uint64_t route_waits, handshake_timeouts, last_connect_error;
    uint64_t upload_bytes, download_bytes, reads, writes, blocked_writes, bulk_directions;
    // Counts are exported in disjoint buckets of <= 16, 32, ...
    // 16384 microseconds, followed by overflow.
    uint64_t connect_us[12], first_byte_us[12];
    uint64_t first_request_write_us[12], request_to_first_guest_byte_us[12];
    uint64_t setup_closes, closes_before_response, idle_guest_closes, stream_errors, resets_forwarded;
    mp_tcp_handoff_stats handoff;
    // Count each newly allocated unwritten suffix once, across both directions.
    uint64_t pending_allocations, pending_copy_bytes;
    // Positive guest reads only. Disjoint counts: <=128, (128,256), =256, >256 KiB.
    uint64_t guest_reads_by_size[4], guest_read_bytes, guest_full_cap_reads;
    // Subset of full-cap reads whose EVFILT_READ data hinted at more than the cap.
    uint64_t guest_full_cap_ready_above_cap;
    // Normal read notifications on already-classified downloads in the flat data queue.
    // Both counts require a full-cap read and a kevent byte hint strictly above the cap.
    uint64_t guest_flat_bulk_full_cap_ready_above_cap;
    // Subset from polls returning <=2 events with room to return at least three.
    uint64_t guest_sparse_flat_bulk_full_cap_ready_above_cap;
    // First actual socket setup error for this lease, even if a retry later
    // succeeds or the overall deadline expires. The stage has static storage.
    const char *first_dial_stage;
    int first_dial_errno;
} mp_tcp_stats;

// A single serial owner must call these functions. The returned kqueue is
// readable whenever drain can make progress. Destroy after closing listeners.
mp_tcp_relay *mp_tcp_relay_create(const char *guest);
// A data owner receives accepted streams from a separate listener owner.
mp_tcp_relay *mp_tcp_relay_create_data(const char *guest);
// Maximum bytes per read syscall on this owner, fixed at creation.
unsigned mp_tcp_relay_read_bytes(const mp_tcp_relay *relay);
// Configure before event processing starts. Applies only to newly dialed guest sockets.
void mp_tcp_relay_bound_guest_window(mp_tcp_relay *relay);
int mp_tcp_relay_scope(mp_tcp_relay *relay, const char *gateway);
// Release each target on its owner, sequentially, before releasing its parent.
typedef void (*mp_tcp_handoff)(void *owner, int client, uint64_t accepted_at);
mp_tcp_listener *mp_tcp_target(mp_tcp_relay *relay, mp_tcp_listener *parent);
void mp_tcp_set_handoff(mp_tcp_listener *listener, mp_tcp_handoff handler, void *owner);
// Call on the accept owner. The worker count is fixed for the relay's lifetime.
unsigned mp_tcp_next_worker(mp_tcp_listener *listener, unsigned workers);
// Takes ownership of the client descriptor, including on failure.
void mp_tcp_adopt(mp_tcp_listener *target, int client, uint64_t accepted_at);
// Profiled handoff only. Timestamps are CLOCK_UPTIME_RAW nanoseconds taken
// immediately after accept and immediately before submission to the owner queue.
void mp_tcp_adopt_profiled(mp_tcp_listener *target, int client, uint64_t accepted_at, uint64_t enqueued_at);
// Thread-safe lock-free handoff into a dedicated data owner's kqueue.
// Wakes the data owner via EVFILT_USER and adopts mid-turn ahead of bulk I/O.
void mp_tcp_handoff_enqueue(mp_tcp_listener *target, int client, uint64_t accepted_at);
void mp_tcp_handoff_enqueue_profiled(mp_tcp_listener *target, int client,
                                     uint64_t accepted_at, uint64_t enqueued_at);
// Thread-safe, coalescing signal for a new handshake that lost the worker path.
int mp_tcp_take_path_failure(mp_tcp_relay *accept_relay);
// Reports newly received guest payload since the previous observation on this I/O owner.
int mp_tcp_take_guest_data(mp_tcp_relay *relay);
int mp_tcp_relay_descriptor(const mp_tcp_relay *relay);
// Maximum events per dispatch callback on a dedicated data worker.
int mp_tcp_data_callback_events(int data_workers);
// Pass the size of the dedicated data group, or zero for the accept owner.
void mp_tcp_relay_drain(mp_tcp_relay *relay, int data_workers);
void mp_tcp_relay_destroy(mp_tcp_relay *relay);

// Binds exactly 127.0.0.1. Returns NULL and sets errno on failure.
mp_tcp_listener *mp_tcp_listen(mp_tcp_relay *relay, uint16_t host_port,
                               uint16_t guest_port, uint16_t *selected, int profile);
void mp_tcp_release(mp_tcp_listener *listener, mp_tcp_stats *stats);

#endif
