#define main filter_work_main
#include "filter_work.c"
#undef main

static void check_totals(mp_tcp_stats *s, int profile, int download, size_t suffix) {
    check(s->upload_bytes == (profile ? PAYLOAD : 0) && s->download_bytes == (profile ? PAYLOAD : 0),
          "balanced verified traffic");
    check(s->blocked_writes == 2u * profile && s->pending_allocations == (unsigned)profile &&
          s->pending_copy_bytes == (profile ? suffix : 0), "aggregate write and copy counters");
#ifdef DIRECTIONAL_STATS
    check(s->download_blocked_writes == (download ? s->blocked_writes : 0) &&
          s->download_pending_allocations == (download ? s->pending_allocations : 0) &&
          s->download_pending_copy_bytes == (download ? s->pending_copy_bytes : 0), "download counters");
#else
    (void)download;
#endif
}

static void transfer(int download, size_t room, int profile) {
    mp_tcp_relay *accept = mp_tcp_relay_create("127.0.0.1"), *r = mp_tcp_relay_create_data("127.0.0.1");
    check(accept && r, "create owners");
    mp_tcp_listener *parent = new_listener(accept, 8080, profile), *l = mp_tcp_target(r, parent);
    check(parent && l, "create listeners");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    if (profile) atomic_fetch_add(&parent->group_active, 1);
    drain(r);
    int *from = download ? guest : client, *to = download ? client : guest;
    struct endpoint *dst = download ? &p->client : &p->guest;
    // One freely draining transfer in the reverse direction keeps both byte totals equal.
    check(write(to[0], payload, PAYLOAD) == PAYLOAD, "reverse write");
    drain(r);
    expect_bytes(from[0], payload, PAYLOAD);
    size_t filled = fill(to[1]);
    consume_padding(to[0], room);
    check(write(from[0], payload, PAYLOAD) == PAYLOAD, "pressured write");
    drain(r);
    check(dst->pending && dst->length > 0 && dst->length <= PAYLOAD, "retained suffix");
    size_t suffix = dst->length;
    check(room ? suffix < PAYLOAD : suffix == PAYLOAD, "partial write or blocked write");
    pump(opposite(dst), dst);
    check(dst->length == suffix, "retry wrote no new data");
    consume_padding(to[0], filled - room);
    expect_bytes(to[0], payload, PAYLOAD-suffix);
    drain(r);
    expect_bytes(to[0], payload + PAYLOAD-suffix, suffix);
    check(shutdown(from[0], SHUT_WR) == 0, "half-close sender");
    drain(r);
    unsigned char c;
    check(read(to[0], &c, 1) == 0 && shutdown(to[0], SHUT_WR) == 0, "half-close receiver");
    drain(r);
    check(read(from[0], &c, 1) == 0 && !l->head, "fully retired");
    mp_tcp_stats target, merged;
    mp_tcp_release(l, &target);
    mp_tcp_release(parent, &merged);
    check_totals(&target, profile, download, suffix);
    check_totals(&merged, profile, download, suffix);
    printf("{\"pressured_destination\":\"%s\",\"room\":%zu,\"profile\":%d,\"suffix\":%zu,"
           "\"verified_each_way\":%u,\"blocked_writes\":%llu,\"allocations\":%llu,\"copy_bytes\":%llu",
           download ? "client" : "guest", room, profile, suffix, PAYLOAD, merged.blocked_writes,
           merged.pending_allocations, merged.pending_copy_bytes);
#ifdef DIRECTIONAL_STATS
    printf(",\"download_blocked_writes\":%llu,\"download_allocations\":%llu,\"download_copy_bytes\":%llu",
           merged.download_blocked_writes, merged.download_pending_allocations, merged.download_pending_copy_bytes);
#endif
    puts("}");
    close(client[0]); close(guest[0]);
    mp_tcp_relay_destroy(r); mp_tcp_relay_destroy(accept);
}

int main(void) {
    alarm(5);
    signal(SIGPIPE, SIG_IGN);
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (unsigned char)(19 + i * 127 + i / 257);
    for (int profile = 0; profile < 2; ++profile)
        for (int download = 0; download < 2; ++download)
            for (int partial = 0; partial < 2; ++partial) transfer(download, partial * PAYLOAD/2, profile);
    return 0;
}
