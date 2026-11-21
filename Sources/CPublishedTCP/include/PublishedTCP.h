#ifndef MICROPOD_PUBLISHED_TCP_H
#define MICROPOD_PUBLISHED_TCP_H

#include <stdint.h>

typedef struct mp_tcp_relay mp_tcp_relay;
typedef struct mp_tcp_listener mp_tcp_listener;

typedef struct {
    uint64_t accepted, connected, connect_errors, connect_retries, recovered, peak_active;
    uint64_t upload_bytes, download_bytes, reads, writes, blocked_writes;
    // Counts are exported in disjoint buckets of <= 16, 32, ...
    // 16384 microseconds, followed by overflow.
    uint64_t connect_us[12], first_byte_us[12];
} mp_tcp_stats;

// A single serial owner must call these functions. The returned kqueue is
// readable whenever drain can make progress. Destroy after closing listeners.
mp_tcp_relay *mp_tcp_relay_create(const char *guest);
int mp_tcp_relay_descriptor(const mp_tcp_relay *relay);
void mp_tcp_relay_drain(mp_tcp_relay *relay);
void mp_tcp_relay_destroy(mp_tcp_relay *relay);

// Binds exactly 127.0.0.1. Returns NULL and sets errno on failure.
mp_tcp_listener *mp_tcp_listen(mp_tcp_relay *relay, uint16_t host_port,
                               uint16_t guest_port, uint16_t *selected, int profile);
void mp_tcp_release(mp_tcp_listener *listener, mp_tcp_stats *stats);

#endif
