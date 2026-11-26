// Darwin relay component benchmark. Insert already-connected endpoints at the
// end of handshake setup so both revisions run the production kqueue data path.
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/resource.h>

#ifndef RELAY_SOURCE
#define RELAY_SOURCE "../../Sources/CPublishedTCP/PublishedTCP.c"
#endif
#include RELAY_SOURCE
#ifndef CONNECT_WRITE_FLAGS
#define CONNECT_WRITE_FLAGS EV_ADD  // Older relay revisions.
#endif

#define STREAMS 32
#define MAX_OWNERS 8
#define BLOCK (256 * 1024)
#define PERIOD_NS 25000000ULL

static int profile, client_capacity, owner_count, port_count, drain_owners;
static atomic_bool stopping;
static unsigned char payload[STREAMS][BLOCK];

// A paired pilot keeps the callback budget fixed and leaves counts behind
// even if the watchdog fires while a client is waiting for its final reply.
struct progress { _Atomic uint32_t submitted, completed; };
_Static_assert(sizeof(struct progress) == 8, "pilot progress file layout");
static struct progress *progress;

#ifdef RELAYBENCH_NATIVE_WORKERS
static void print_worker_controls(unsigned read_bytes) {
    printf("\"workers\":%d,\"drain_workers\":%d,\"callback_events\":%d,\"read_bytes\":%u,",
           owner_count, drain_owners, mp_tcp_data_callback_events(drain_owners), read_bytes);
}
#endif

struct owner {
    mp_tcp_relay *relay;
    dispatch_queue_t queue;
    dispatch_source_t source;
    dispatch_semaphore_t cancelled;
};

struct lease {
    mp_tcp_listener *listener, *targets[MAX_OWNERS];
#ifdef LEGACY_HANDOFF
    unsigned next;
#endif
};

static struct owner owners[MAX_OWNERS];
static struct lease leases[STREAMS];
static dispatch_queue_t accept_queue;

struct flow {
    int client, guest, index;
    atomic_uint_fast64_t received;
    uint64_t written;
    pthread_t reader, writer;
};

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void check(bool ok, const char *what) {
    if (!ok) { fprintf(stderr, "%s (errno %d)\n", what, errno); exit(1); }
}

static uint64_t process_cpu_us(void) {
    struct rusage usage;
    check(getrusage(RUSAGE_SELF, &usage) == 0, "process CPU time");
    return (uint64_t)(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000 +
           usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}

static struct rusage_info_v6 host_usage(void) {
    struct rusage_info_v6 value = {0};
    check(proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&value) == 0, "host runnable time");
    return value;
}

static void until(uint64_t target) {
    for (;;) {
        uint64_t now = now_ns();
        if (now >= target) return;
        uint64_t left = target - now;
        struct timespec time = { (time_t)(left / 1000000000), (long)(left % 1000000000) };
        nanosleep(&time, NULL);
    }
}

static void start_owner(struct owner *o) {
    o->relay = mp_tcp_relay_create_data("127.0.0.1");
    check(o->relay != NULL, "create relay");
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                         QOS_CLASS_USER_INITIATED, 0);
    o->queue = dispatch_queue_create("dev.micropod.bench.relay", attr);
    o->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                       (uintptr_t)mp_tcp_relay_descriptor(o->relay), 0, o->queue);
    o->cancelled = dispatch_semaphore_create(0);
    dispatch_source_set_event_handler(o->source, ^{ mp_tcp_relay_drain(o->relay, drain_owners); });
    dispatch_source_set_cancel_handler(o->source, ^{ dispatch_semaphore_signal(o->cancelled); });
    dispatch_activate(o->source);
}

static void stop_owner(struct owner *o) {
    dispatch_source_cancel(o->source);
    dispatch_semaphore_wait(o->cancelled, DISPATCH_TIME_FOREVER);
    mp_tcp_relay_destroy(o->relay);
    dispatch_release(o->source);
    dispatch_release(o->queue);
    dispatch_release(o->cancelled);
}

static void open_lease(struct lease *l, mp_tcp_relay *accept_relay, uint16_t port) {
    l->listener = new_listener(accept_relay, port, profile);
    check(l->listener != NULL, "create lease");
    for (int j = 0; j < owner_count; ++j) {
        l->targets[j] = mp_tcp_target(owners[j].relay, l->listener);
        check(l->targets[j] != NULL, "create lease target");
    }
}

static mp_tcp_stats release_lease(struct lease *l) {
    for (int j = 0; j < owner_count; ++j)
        dispatch_sync(owners[j].queue, ^{ mp_tcp_release(l->targets[j], NULL); });
    mp_tcp_stats stats;
    mp_tcp_release(l->listener, &stats);
    return stats;
}

static void connected_fds(int fds[2], int capacity) {
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0, "socketpair");
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) == 0, "socket buffer");
    }
    check(fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0, "nonblocking relay endpoint");
}

static unsigned attach(struct lease *lease, int *client_fd, int *guest_fd) {
    int client[2], guest[2];
    connected_fds(client, client_capacity);
    connected_fds(guest, 512 * 1024);
    *client_fd = client[0];
    *guest_fd = guest[0];
    struct pair *p = calloc(1, sizeof(*p));
    check(p != NULL, "allocate stream");
    p->client = (struct endpoint){ .watch = { STREAM, client[1] }, .pair = p };
    p->guest = (struct endpoint){ .watch = { STREAM, guest[1] }, .pair = p };
    p->accepted_at = now_ns();
    __block unsigned index;
    dispatch_sync(accept_queue, ^{
#ifdef LEGACY_HANDOFF
        // NativeLoopbackRelay.Lease.adopt on the baseline revision.
        index = lease->next;
        lease->next = (index + 1) % (unsigned)owner_count;
#else
        index = mp_tcp_next_worker(lease->listener, (unsigned)owner_count);
#endif
    });
    struct owner *o = &owners[index];
    mp_tcp_listener *l = lease->targets[index];
    p->listener = l;
    dispatch_sync(o->queue, ^{
        p->next = l->head;
        if (p->next) p->next->prev = p;
        l->head = p;
        ++l->active;
        if (l->profile) atomic_fetch_add(&l->parent->group_active, 1);
#ifdef RELAYBENCH_STAGE_CONNECT
        // Both filter-pilot arms start at writable guest-handshake completion.
        // The connected local descriptors exercise finish_connect on the owner.
        p->guest.connecting = true;
        check(watch_fd(o->relay, &p->client.watch, EVFILT_READ, EV_ADD | EV_DISABLE) == 0 &&
              watch_fd(o->relay, &p->guest.watch, EVFILT_READ, EV_ADD | EV_DISABLE) == 0 &&
              watch_fd(o->relay, &p->guest.watch, EVFILT_WRITE, CONNECT_WRITE_FLAGS) == 0, "register connecting stream");
#else
        connected(p);
        check(watch_fd(o->relay, &p->client.watch, EVFILT_READ, EV_ADD) == 0 &&
              watch_fd(o->relay, &p->guest.watch, EVFILT_READ, EV_ADD) == 0, "register stream");
#endif
    });
    return index;
}

static void send_bytes(int fd, const void *buffer, size_t length) {
    const char *data = buffer;
    while (length) {
        ssize_t n = write(fd, data, length);
        if (n < 0 && errno == EINTR) continue;
        check(n > 0, "write bytes");
        data += n;
        length -= (size_t)n;
    }
}

static ssize_t receive(int fd, void *buffer, size_t size) {
    ssize_t n;
    do { n = read(fd, buffer, size); } while (n < 0 && errno == EINTR);
    check(n >= 0, "read bytes");
    return n;
}

static void *bulk_writer(void *arg) {
    struct flow *f = arg;
    while (!atomic_load_explicit(&stopping, memory_order_relaxed)) {
        send_bytes(f->guest, payload[f->index], BLOCK);
        f->written += BLOCK;
    }
    check(shutdown(f->guest, SHUT_WR) == 0, "bulk guest FIN");
    return NULL;
}

static void *bulk_reader(void *arg) {
    struct flow *f = arg;
    unsigned char *buf = malloc(BLOCK);
    check(buf != NULL, "reader buffer");
    uint64_t total = 0;
    size_t n;
    while ((n = (size_t)receive(f->client, buf, BLOCK)) > 0) {
        size_t offset = total % BLOCK;
        size_t first = n < BLOCK - offset ? n : BLOCK - offset;
        check(memcmp(buf, payload[f->index] + offset, first) == 0 &&
              memcmp(buf + first, payload[f->index], n - first) == 0, "bulk payload mismatch");
        total += n;
        atomic_store_explicit(&f->received, total, memory_order_relaxed);
    }
    free(buf);
    return NULL;
}

static void read_message_and_fin(int fd, uint64_t expected) {
    uint64_t got;
    size_t used = 0;
    while (used < sizeof(got)) {
        ssize_t n = receive(fd, (char *)&got + used, sizeof(got) - used);
        check(n > 0, "premature FIN");
        used += (size_t)n;
    }
    char extra;
    check(got == expected && receive(fd, &extra, 1) == 0, "probe identity or FIN");
}

static void probe(struct lease *lease, uint64_t id) {
    int client, guest;
    attach(lease, &client, &guest);
    send_bytes(client, &id, sizeof(id));
    check(shutdown(client, SHUT_WR) == 0, "probe client FIN");
    read_message_and_fin(guest, id);
    id = ~id;
    send_bytes(guest, &id, sizeof(id));
    check(shutdown(guest, SHUT_WR) == 0, "probe guest FIN");
    read_message_and_fin(client, id);
    close(client);
    close(guest);
}

struct arrival {
    struct lease *lease;
    uint64_t id, target, dispatch_delay, elapsed;
    pthread_t thread;
};

static void *fresh_client(void *arg) {
    struct arrival *a = arg;
    a->dispatch_delay = now_ns() - a->target;
    probe(a->lease, a->id);
    a->elapsed = now_ns() - a->target;
    if (progress) atomic_fetch_add_explicit(&progress->completed, 1, memory_order_relaxed);
    return NULL;
}

// Close an active lease that has streams on every owner. Keep a sibling open
// and exercise a new lease for the same logical target after the fence.
static void check_revocation(mp_tcp_relay *accept_relay) {
    struct lease old = {0}, sibling = {0}, replacement = {0};
    open_lease(&old, accept_relay, 9000);
    open_lease(&sibling, accept_relay, 9001);
    int client[MAX_OWNERS], guest[MAX_OWNERS], live_client, live_guest;
    attach(&sibling, &live_client, &live_guest);
    unsigned mask = 0;
    for (int i = 0; i < owner_count; ++i)
        mask |= 1U << attach(&old, &client[i], &guest[i]);
    check(mask == (1U << owner_count) - 1, "active lease placement");
    release_lease(&old);
    open_lease(&replacement, accept_relay, 9000);
    probe(&replacement, 37);
    for (int i = 0; i < owner_count; ++i) {
        char buf;
        check(receive(client[i], &buf, 1) == 0 && receive(guest[i], &buf, 1) == 0, "revoked stream");
        close(client[i]);
        close(guest[i]);
    }
    uint64_t marker = 59;
    send_bytes(live_guest, &marker, sizeof(marker));
    check(shutdown(live_guest, SHUT_WR) == 0, "sibling FIN");
    read_message_and_fin(live_client, marker);
    close(live_client);
    close(live_guest);
    release_lease(&sibling);
    release_lease(&replacement);
}

static void stop_relays(mp_tcp_relay *accept_relay) {
    for (int i = 0; i < owner_count; ++i) stop_owner(&owners[i]);
    mp_tcp_relay_destroy(accept_relay);
    dispatch_release(accept_queue);
}

int main(int argc, char **argv) {
    if (argc != 6 && argc != 7) {
        fprintf(stderr, "usage: relay SECONDS|check CLIENT_BUFFER_KiB PROFILE_0_OR_1 OWNERS PORTS [FIXED_128_PROGRESS_FILE]\n");
        return 2;
    }
    int seconds = atoi(argv[1]), kib = atoi(argv[2]);
    bool check_only = strcmp(argv[1], "check") == 0 && argc == 6;
    profile = atoi(argv[3]);
    owner_count = atoi(argv[4]);
    port_count = atoi(argv[5]);
    check((check_only || (seconds >= 1 && seconds <= 60)) && kib >= 8 && kib <= 1024 && (profile == 0 || profile == 1) &&
          owner_count >= 1 && owner_count <= MAX_OWNERS && port_count >= 1 && port_count <= STREAMS, "arguments");
    drain_owners = owner_count;
    if (argc == 7) {
        int fd = open(argv[6], O_RDWR);
        check(fd >= 0 && lseek(fd, 0, SEEK_END) == sizeof(*progress), "open pilot progress file");
        progress = mmap(NULL, sizeof(*progress), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        check(progress != MAP_FAILED, "map pilot progress file");
        close(fd);
        atomic_init(&progress->submitted, 0);
        atomic_init(&progress->completed, 0);
#ifndef RELAYBENCH_NATIVE_WORKERS
        // Legacy relay revisions predate the fixed-budget build option.
        drain_owners = 2;
#endif
    }
    client_capacity = kib * 1024;
    signal(SIGPIPE, SIG_IGN);
    alarm((unsigned)seconds + 35);

    struct flow flows[STREAMS] = {0};
    unsigned distribution[MAX_OWNERS] = {0};
    for (int i = 0; i < owner_count; ++i) start_owner(&owners[i]);
#ifdef RELAYBENCH_NATIVE_WORKERS
#ifdef MICROPOD_BENCH_512K_READS
    unsigned read_bytes = mp_tcp_relay_read_bytes(owners[0].relay);
    for (int i = 1; i < owner_count; ++i)
        check(mp_tcp_relay_read_bytes(owners[i].relay) == read_bytes, "inconsistent owner read limits");
#else
    unsigned read_bytes = CHUNK;  // Older revisions read directly up to this compile-time limit.
#endif
#endif
    mp_tcp_relay *accept_relay = mp_tcp_relay_create("127.0.0.1");
    check(accept_relay != NULL, "accept relay");
    accept_queue = dispatch_queue_create("dev.micropod.bench.accept",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    if (check_only) {
        check_revocation(accept_relay);
        stop_relays(accept_relay);
        putchar('{');
#ifdef RELAYBENCH_NATIVE_WORKERS
        print_worker_controls(read_bytes);
#endif
        puts("\"live_revocation\":true,\"sibling_and_reuse\":true,\"timed_rounds\":0}");
        return 0;
    }
    for (int i = 0; i < port_count; ++i) open_lease(&leases[i], accept_relay, (uint16_t)(8080 + i));
    fprintf(stderr, "attaching bulk streams\n");
    for (int i = 0; i < STREAMS; ++i) {
        struct flow *f = &flows[i];
        f->index = i;
        uint32_t seed = 1 + i;
        for (size_t j = 0; j < BLOCK; ++j) {
            seed = seed * 1664525U + 1013904223U;
            payload[i][j] = (unsigned char)(seed >> 24);
        }
        unsigned index = attach(&leases[i % port_count], &f->client, &f->guest);
        ++distribution[index];
        check(shutdown(f->client, SHUT_WR) == 0, "bulk client FIN");
        check(pthread_create(&f->reader, NULL, bulk_reader, f) == 0 &&
              pthread_create(&f->writer, NULL, bulk_writer, f) == 0, "start bulk flow");
    }
    fprintf(stderr, "warming all streams\n");
    for (int i = 0; i < STREAMS; ++i) {
        while (atomic_load(&flows[i].received) < 4 * BLOCK) usleep(1000);
    }
    int arrivals = seconds * 40;
    struct arrival *probes = calloc((size_t)arrivals, sizeof(*probes));
    check(probes != NULL, "probe samples");
    uint64_t bytes[STREAMS], total = 0;
    fprintf(stderr, "scoring loaded requests\n");
    for (int i = 0; i < STREAMS; ++i) bytes[i] = atomic_load(&flows[i].received);
    uint64_t cpu_start = process_cpu_us();
    struct rusage_info_v6 host_start = {0}, host_end = {0};
    if (progress) host_start = host_usage();
    uint64_t begin = now_ns();
    for (int i = 0; i < arrivals; ++i) {
        uint64_t target = begin + i * PERIOD_NS;
        until(target);
        struct arrival *a = &probes[i];
        a->lease = &leases[i % port_count];
        a->id = (uint64_t)i + 1;
        a->target = target;
        // A blocked client must never occupy a libdispatch thread needed by
        // the relay to complete that client's read. The real client is external.
        if (progress) atomic_store_explicit(&progress->submitted, (uint32_t)i + 1, memory_order_relaxed);
        check(pthread_create(&a->thread, NULL, fresh_client, a) == 0, "start fresh client");
    }
    until(begin + arrivals * PERIOD_NS);
    uint64_t elapsed = now_ns() - begin;
    if (progress) host_end = host_usage();
    uint64_t cpu_us = process_cpu_us() - cpu_start;
    for (int i = 0; i < STREAMS; ++i) {
        bytes[i] = atomic_load(&flows[i].received) - bytes[i];
        check(bytes[i] > 0, "stalled bulk flow");
        total += bytes[i];
    }
    fprintf(stderr, "waiting for final probes\n");
    for (int i = 0; i < arrivals; ++i) pthread_join(probes[i].thread, NULL);
    atomic_store(&stopping, true);
    fprintf(stderr, "draining bulk streams\n");
    for (int i = 0; i < STREAMS; ++i) {
        struct flow *f = &flows[i];
        pthread_join(f->writer, NULL);
        pthread_join(f->reader, NULL);
        check(f->written == atomic_load(&f->received), "bulk byte count");
        close(f->client);
        close(f->guest);
    }
    uint64_t reads = 0, writes = 0, blocked = 0;
    fprintf(stderr, "releasing scored leases\n");
    for (int i = 0; i < port_count; ++i) {
        mp_tcp_stats stats = release_lease(&leases[i]);
        check(stats.stream_errors == 0, "relay stream errors");
        reads += stats.reads;
        writes += stats.writes;
        blocked += stats.blocked_writes;
    }
    fprintf(stderr, "checking live revocation\n");
    check_revocation(accept_relay);
    fprintf(stderr, "stopping data owners\n");
    stop_relays(accept_relay);
    printf("{");
    if (progress) {
        mach_timebase_info_data_t tb;
        check(mach_timebase_info(&tb) == KERN_SUCCESS, "Mach timebase");
#ifdef RELAYBENCH_NATIVE_WORKERS
        print_worker_controls(read_bytes);
#else
        printf("\"callback_events\":128,");
#endif
        printf("\"runnable_ticks\":%llu,\"cpu_ticks\":%llu,\"tick_numer\":%u,\"tick_denom\":%u,",
               host_end.ri_runnable_time - host_start.ri_runnable_time,
               host_end.ri_user_time - host_start.ri_user_time + host_end.ri_system_time - host_start.ri_system_time,
               tb.numer, tb.denom);
        munmap(progress, sizeof(*progress));
    }
    printf("\"bytes\":%llu,\"elapsed_ns\":%llu,\"process_cpu_us\":%llu,\"profile\":%d,\"client_buffer_kib\":%d,"
           "\"ports\":%d,\"relay_reads\":%llu,\"relay_writes\":%llu,\"blocked_writes\":%llu,\"bulk_flows_per_owner\":[",
           total, elapsed, cpu_us, profile, kib, port_count, reads, writes, blocked);
    for (int i = 0; i < owner_count; ++i) printf("%s%u", i ? "," : "", distribution[i]);
    printf("],\"per_stream_bytes\":[");
    for (int i = 0; i < STREAMS; ++i) printf("%s%llu", i ? "," : "", bytes[i]);
    printf("],\"fresh_ns\":[");
    for (int i = 0; i < arrivals; ++i) printf("%s%llu", i ? "," : "", probes[i].elapsed);
    printf("],\"dispatch_ns\":[");
    for (int i = 0; i < arrivals; ++i) printf("%s%llu", i ? "," : "", probes[i].dispatch_delay);
    printf("]}\n");
    free(probes);
    return 0;
}
