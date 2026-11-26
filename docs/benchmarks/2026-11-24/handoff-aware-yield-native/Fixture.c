// Compile only in the native test executable. The separate benchmark executable
// links the candidate C implementation directly, without these observations.
#include <assert.h>
#include <sys/time.h>

#define mp_tcp_relay_drain candidate_drain
#include "PublishedTCP.c"
#undef mp_tcp_relay_drain
#include "Fixture.h"

static _Atomic(mp_tcp_relay *) tracked_owner;
static mp_tcp_listener *tracked;
static atomic_uint productive_callbacks, largest_callback_bytes;

void mp_tcp_relay_drain(mp_tcp_relay *owner, int workers) {
    // Only the owning serial queue reads lease state or mutates the counters.
    if (atomic_load(&tracked_owner) != owner) {
        candidate_drain(owner, workers);
        return;
    }
    uint64_t before = tracked->stats.download_bytes;
    candidate_drain(owner, workers);
    uint64_t delivered = tracked->stats.download_bytes - before;
    if (delivered > 0) {
        atomic_fetch_add(&productive_callbacks, 1);
        if (delivered > atomic_load(&largest_callback_bytes)) {
            assert(delivered <= UINT32_MAX);
            atomic_store(&largest_callback_bytes, (unsigned)delivered);
        }
    }
}

mp_tcp_listener *fixture_parent(mp_tcp_relay *owner, int profile) {
    return new_listener(owner, 8080, profile);
}

unsigned fixture_pending(mp_tcp_relay *owner) {
    return atomic_load(&owner->pending_handoffs);
}

unsigned fixture_productive_callbacks(mp_tcp_relay *owner) {
    assert(atomic_load(&tracked_owner) == owner);
    return atomic_load(&productive_callbacks);
}

unsigned fixture_largest_callback_bytes(mp_tcp_relay *owner) {
    assert(atomic_load(&tracked_owner) == owner);
    return atomic_load(&largest_callback_bytes);
}

// Own both relay descriptors exactly as an established stream would. Fill the
// entire anonymous guest socket before making the read filter visible to dispatch.
int fixture_stage_bulk(mp_tcp_listener *target) {
    enum { PAYLOAD_BYTES = 768 * 1024, ROOM = 1024 * 1024 };
    assert(target->profile && target->parent && atomic_load(&tracked_owner) == NULL);
    int client[2], guest[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, client) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, guest) == 0);
    int room = ROOM;
    for (unsigned i = 0; i < 2; ++i) {
        for (unsigned j = 0; j < 2; ++j) {
            const int fd = j == 0 ? client[i] : guest[i];
            assert(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &room, sizeof(room)) == 0);
            assert(setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &room, sizeof(room)) == 0);
        }
    }
    struct timeval timeout = {.tv_sec = 5};
    assert(setsockopt(client[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    assert(fcntl(client[1], F_SETFL, O_NONBLOCK) == 0);
    assert(fcntl(guest[1], F_SETFL, O_NONBLOCK) == 0);
    unsigned char *payload = malloc(PAYLOAD_BYTES);
    assert(payload != NULL);
    memset(payload, 0x5a, PAYLOAD_BYTES);
    assert(send(guest[0], payload, PAYLOAD_BYTES, MSG_DONTWAIT) == PAYLOAD_BYTES);
    free(payload);
    assert(shutdown(guest[0], SHUT_WR) == 0);
    close(guest[0]);
    struct pair *p = calloc(1, sizeof(*p));
    assert(p != NULL && target->head == NULL);
    p->listener = target;
    p->client = (struct endpoint){.watch = {STREAM, client[1]}, .pair = p};
    p->guest = (struct endpoint){.watch = {STREAM, guest[1]}, .pair = p};
    target->head = p;
    ++target->active;
    atomic_fetch_add(&target->parent->group_active, 1);
    atomic_store(&productive_callbacks, 0);
    atomic_store(&largest_callback_bytes, 0);
    tracked = target;
    atomic_store(&tracked_owner, target->relay);
    assert(watch_fd(target->relay, &p->guest.watch, EVFILT_READ, EV_ADD) == 0);
    return client[0];
}

void fixture_finish_bulk(mp_tcp_listener *target) {
    assert(tracked == target);
    assert(atomic_exchange(&tracked_owner, NULL) == target->relay);
    tracked = NULL;
}
