// Released room is fixed in bytes. The normal data owner decides when to flush.
#define main unused_control_fixture
#include "filter_work.c"
#undef main

static void cell(size_t suffix, size_t step) {
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create owner");
    mp_tcp_listener *lease = new_listener(owner, 8080, 1);
    int client[2], guest[2];
    struct pair *pair = stage(lease, client, guest);
    drain(owner);
    for (size_t i = 0; i < sizeof(payload); i++) payload[i] = (unsigned char)(i*7+11);
    size_t filler = fill(client[1]);
    check(write(guest[0], payload, suffix) == (ssize_t)suffix, "offer payload");
    check(shutdown(guest[0], SHUT_WR) == 0, "FIN after offered payload");
    drain(owner);
    check(pair->client.pending && pair->client.length == suffix, "entire suffix retained");
    uint64_t before = lease->stats.writes;
    size_t released = 0, first = 0, done = 0;
    printf("{\"suffix\":%zu,\"step\":%zu,\"initial_filler\":%zu,\"rows\":[",suffix,step,filler);
    while (released < filler) {
        size_t chunk = filler-released < step ? filler-released : step;
        consume_padding(client[0],chunk);
        released += chunk;
        drain(owner);
        size_t bytes = lease->stats.download_bytes;
        if (!first && bytes) first = released;
        if (!done && bytes == suffix) done = released;
        printf("%s[%zu,%zu,%llu]",released==chunk?"":",",released,bytes,
               (unsigned long long)(lease->stats.writes-before));
        if (done) break;
    }
    check(done == 0 || done <= filler, "progress range");
    if (released < filler) consume_padding(client[0], filler-released);
    drain(owner);
    check(lease->stats.download_bytes==suffix && !pair->client.pending, "flushed after all room");
    expect_bytes(client[0],payload,suffix);
    unsigned char marker = 23, end;
    check(read(client[0],&end,1)==0, "forward FIN");
    check(write(client[0],&marker,1)==1 && shutdown(client[0],SHUT_WR)==0,"return reply");
    drain(owner);
    expect_bytes(guest[0],&marker,1);
    check(read(guest[0],&end,1)==0 && !lease->head,"return FIN and retire");
    printf("],\"room_at_first_progress\":%zu,\"room_at_full_flush\":%zu,\"delivery\":%zu,\"reverse_bytes\":1,\"dual_fin\":true}\n", first, done,suffix);
    close(client[0]); close(guest[0]); mp_tcp_release(lease,NULL); mp_tcp_relay_destroy(owner);
}
int main(void) {
    signal(SIGPIPE,SIG_IGN);
    const size_t suffixes[]={4096,32768}, steps[]={2048,8192,32768};
    for(size_t i=0;i<2;i++) for(size_t j=0;j<3;j++) cell(suffixes[i],steps[j]);
    return 0;
}
