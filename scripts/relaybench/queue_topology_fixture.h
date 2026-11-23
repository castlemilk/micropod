// Test-only adapter included after the fixture's socket instrumentation.
// Include the pinned production implementation before redirecting fixture calls.
#include "PublishedTCP.c"

#ifdef COMPARE_QUEUE_ORDER
static mp_tcp_relay *fixture_create_owner(const char *guest) {
    const char *mode = getenv("RELAYBENCH_OWNER_TOPOLOGY");
    if (!mode || (strcmp(mode, "flat") && strcmp(mode, "nested"))) abort();
    bool nested = !strcmp(mode, "nested");
    mp_tcp_relay *r = nested ? mp_tcp_relay_create(guest) : mp_tcp_relay_create_data(guest);
    if (!r || (r->bulk.fd >= 0) != nested || mp_tcp_relay_read_bytes(r) != 512 * 1024 ||
        mp_tcp_data_callback_events(2) != EVENTS_PER_TURN) abort();
    // Count actual kevent polls without reducing either native maximum.
    poll_width = EVENTS_PER_TURN;
    return r;
}
#define mp_tcp_relay_create_data fixture_create_owner
#endif

static void fixture_drain(mp_tcp_relay *r, int unused_workers) {
    (void)unused_workers;
    mp_tcp_relay_drain(r, 2);
#ifdef COMPARE_QUEUE_ORDER
    // The split mode may return to dispatch after servicing interactive events.
    // Drive an extra callback when establishing or half-closing flows.
    if (!active) mp_tcp_relay_drain(r, 2);
#endif
}
#define mp_tcp_relay_drain fixture_drain
