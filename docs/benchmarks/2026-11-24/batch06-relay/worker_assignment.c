// Compare reservation-based and rotating assignment on the same real C owners.
#define main existing_fixture_main
#include "filter_work.c"
#undef main

enum { LONG_LIVED = 32, FRESH = 240, MAX_OWNERS = 4, BULK = 32768 };
struct connection { int client[2], guest[2], worker; };
static mp_tcp_relay *owners[MAX_OWNERS];
static mp_tcp_listener *targets[MAX_OWNERS], *parent;
static unsigned char body[BULK];
static int reservations[MAX_OWNERS], long_count[MAX_OWNERS], retired_count, marker_count;
static unsigned long long bulk_bytes[MAX_OWNERS];

static struct connection open_flow(int workers, bool least, bool lasting) {
    struct connection f;
    unsigned first = mp_tcp_next_worker(parent, (unsigned)workers), chosen = first;
    if (least) {
        for (unsigned j = 1; j < (unsigned)workers; j++) {
            unsigned k = (first+j) % (unsigned)workers;
            if (reservations[k] < reservations[chosen]) chosen = k;
        }
    }
    f.worker = (int)chosen;
    reservations[chosen]++;
    long_count[chosen] += lasting;
    stage(targets[chosen], f.client, f.guest);
    drain(owners[chosen]);
    return f;
}

static void finish(struct connection f) {
    unsigned char marker = (unsigned char)(retired_count * 5 + 1), unused;
    check(shutdown(f.guest[0], SHUT_WR) == 0, "guest FIN");
    drain(owners[f.worker]);
    check(read(f.client[0], &unused, 1) == 0, "receive FIN");
    check(write(f.client[0], &marker, 1) == 1 && shutdown(f.client[0], SHUT_WR) == 0, "return marker and FIN");
    drain(owners[f.worker]);
    expect_bytes(f.guest[0], &marker, 1);
    check(read(f.guest[0], &unused, 1) == 0, "return FIN");
    check(--reservations[f.worker] == (int)targets[f.worker]->active, "balanced reservation");
    close(f.client[0]); close(f.guest[0]); retired_count++;
}

static void short_flow(int workers, bool least) {
    struct connection f = open_flow(workers, least, false);
    unsigned char marker = (unsigned char)(marker_count * 11 + 7);
    check(write(f.guest[0], &marker, 1) == 1, "fresh reply");
    drain(owners[f.worker]);
    expect_bytes(f.client[0], &marker, 1);
    marker_count++; finish(f);
}

static void cell(int workers, bool least, int workload) {
    mp_tcp_relay *accept_owner = mp_tcp_relay_create("127.0.0.1");
    check(accept_owner != NULL, "accept owner");
    parent = new_listener(accept_owner, 8080, 0);
    check(parent != NULL, "parent");
    for (int w = 0; w < workers; w++) {
        owners[w] = mp_tcp_relay_create_data("127.0.0.1");
        check(owners[w] != NULL, "data owner");
        targets[w] = mp_tcp_target(owners[w], parent);
        check(targets[w] != NULL, "target");
    }
    memset(reservations, 0, sizeof(reservations));
    memset(long_count, 0, sizeof(long_count));
    memset(bulk_bytes, 0, sizeof(bulk_bytes));
    retired_count = marker_count = 0;
    struct connection long_lived[LONG_LIVED];
    for (int i = 0; i < LONG_LIVED; i++) {
        long_lived[i] = open_flow(workers, least, true);
        if (workload == 1) short_flow(workers, least);
    }
    for (int i = marker_count; i < FRESH; i++) short_flow(workers, least);
    for (int i = 0; i < LONG_LIVED; i++) {
        struct connection f = long_lived[i];
        size_t bytes = workload == 2 && i % 2 ? 17 : BULK;
        for (size_t j = 0; j < bytes; j++) body[j] = (unsigned char)(i+j*7);
        check(write(f.guest[0], body, bytes) == (ssize_t)bytes, "bulk offer");
        drain(owners[f.worker]);
        expect_bytes(f.client[0], body, bytes);
        bulk_bytes[f.worker] += bytes;
        finish(f);
    }
    printf("{\"workload\":%d,\"workers\":%d,\"long_lived\":[", workload, workers);
    for (int w = 0; w < workers; w++) printf("%s%d", w ? "," : "", long_count[w]);
    printf("],\"verified_bulk_bytes\":[");
    for (int w = 0; w < workers; w++) printf("%s%llu", w ? "," : "", bulk_bytes[w]);
    printf("],\"fresh_delivered\":%d,\"flows_retired\":%d}\n", marker_count, retired_count);
    for (int w=0; w<workers; w++) {
        check(!targets[w]->active && !reservations[w], "all reservations returned");
        mp_tcp_release(targets[w], NULL); mp_tcp_relay_destroy(owners[w]);
    }
    mp_tcp_release(parent, NULL); mp_tcp_relay_destroy(accept_owner);
}

int main(int argc, char **argv) {
    check(argc == 2, "one assignment policy");
    for (int w = 2; w <= 4; w+=2)
        for (int mode = 0; mode < 3; mode++) cell(w, atoi(argv[1]) != 0, mode);
    return 0;
}
