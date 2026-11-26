// Paired Darwin loopback TCP benchmark: legacy GCD dispatch_async handoff vs
// lock-free MPSC + EVFILT_USER mid-turn handoff on single-port 32-stream + 40 req/s load.
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "../../Sources/CPublishedTCP/PublishedTCP.c"

#define BULK_STREAMS 32
#define WORKERS 2
#define BLOCK_BYTES (256 * 1024)
#define FRESH_PERIOD_NS 25000000ULL

static atomic_bool g_stop;
static uint16_t g_backend_port;
static uint16_t g_relay_port;
static unsigned char g_payload[BLOCK_BYTES];

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void die(const char *msg) {
    fprintf(stderr, "FATAL: %s (errno=%d)\n", msg, errno);
    exit(1);
}

static uint64_t proc_cpu_us(void) {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) die("getrusage");
    return (uint64_t)(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000ULL +
           (uint64_t)(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec);
}

static void write_all(int fd, const void *buf, size_t len) {
    const unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE || errno == ECONNRESET) return;
            die("write_all");
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
}

static ssize_t read_exact(int fd, void *buf, size_t len) {
    unsigned char *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return (ssize_t)got;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

static int tcp_connect_loopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_in sa = {
        .sin_len = sizeof(sa),
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    while (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        if (errno == EINTR) continue;
        die("connect");
    }
    return fd;
}

// Backend protocol: client sends 1 byte: 'B' = bulk download stream, 'F' + 8-byte token = echo ~token + close.
static void *backend_conn(void *arg) {
    int fd = (int)(intptr_t)arg;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    unsigned char cmd = 0;
    if (read_exact(fd, &cmd, 1) != 1) { close(fd); return NULL; }
    if (cmd == 'B') {
        while (!atomic_load_explicit(&g_stop, memory_order_relaxed)) {
            ssize_t n = write(fd, g_payload, BLOCK_BYTES);
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (n == 0) break;
        }
    } else if (cmd == 'F') {
        uint64_t tok = 0;
        if (read_exact(fd, &tok, sizeof(tok)) == (ssize_t)sizeof(tok)) {
            uint64_t reply = ~tok;
            write_all(fd, &reply, sizeof(reply));
        }
    }
    close(fd);
    return NULL;
}

static int g_backend_listen = -1;

static void *backend_accept_loop(void *arg) {
    (void)arg;
    for (;;) {
        int fd = accept(g_backend_listen, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, backend_conn, (void *)(intptr_t)fd) != 0) close(fd);
        pthread_attr_destroy(&attr);
    }
    return NULL;
}

struct relay_owner {
    mp_tcp_relay *relay;
    dispatch_queue_t queue;
    dispatch_source_t source;
    dispatch_semaphore_t done;
};

struct relay_lease {
    mp_tcp_listener *listener;
    mp_tcp_listener *targets[WORKERS];
    struct relay_owner *owners;
};

static void start_relay_owner(struct relay_owner *o, int data_workers) {
    o->relay = data_workers ? mp_tcp_relay_create_data("127.0.0.1") : mp_tcp_relay_create("127.0.0.1");
    if (!o->relay) die("mp_tcp_relay_create");
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    o->queue = dispatch_queue_create(data_workers ? "bench.io" : "bench.accept", attr);
    o->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                       (uintptr_t)mp_tcp_relay_descriptor(o->relay), 0, o->queue);
    o->done = dispatch_semaphore_create(0);
    dispatch_source_set_event_handler(o->source, ^{ mp_tcp_relay_drain(o->relay, data_workers); });
    dispatch_source_set_cancel_handler(o->source, ^{ dispatch_semaphore_signal(o->done); });
    dispatch_activate(o->source);
}

static void stop_relay_owner(struct relay_owner *o) {
    dispatch_source_cancel(o->source);
    dispatch_semaphore_wait(o->done, DISPATCH_TIME_FOREVER);
    mp_tcp_relay_destroy(o->relay);
    dispatch_release(o->source);
    dispatch_release(o->queue);
    dispatch_release(o->done);
}

static void on_handoff(void *ctx, int client, uint64_t accepted_at) {
    struct relay_lease *lease = ctx;
    unsigned idx = mp_tcp_next_worker(lease->listener, WORKERS);
    mp_tcp_listener *target = lease->targets[idx];
    uint64_t enqueued_at = now_ns();
#ifdef LEGACY_GCD_HANDOFF
    dispatch_async(lease->owners[idx].queue, ^{
        mp_tcp_adopt_profiled(target, client, accepted_at, enqueued_at);
    });
#else
    mp_tcp_handoff_enqueue_profiled(target, client, accepted_at, enqueued_at);
#endif
}

struct bulk_client {
    atomic_uint_fast64_t bytes;
    pthread_t thread;
};

static void *bulk_client_thread(void *arg) {
    struct bulk_client *bc = arg;
    int fd = tcp_connect_loopback(g_relay_port);
    unsigned char cmd = 'B';
    write_all(fd, &cmd, 1);
    unsigned char *buf = malloc(BLOCK_BYTES);
    if (!buf) die("malloc");
    while (!atomic_load_explicit(&g_stop, memory_order_relaxed)) {
        ssize_t n = read(fd, buf, BLOCK_BYTES);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        atomic_fetch_add_explicit(&bc->bytes, (uint64_t)n, memory_order_relaxed);
    }
    free(buf);
    close(fd);
    return NULL;
}

struct fresh_req {
    uint64_t token;
    uint64_t target_ns;
    uint64_t elapsed_ns;
    pthread_t thread;
};

static void *fresh_req_thread(void *arg) {
    struct fresh_req *r = arg;
    int fd = tcp_connect_loopback(g_relay_port);
    unsigned char req[9];
    req[0] = 'F';
    memcpy(req + 1, &r->token, 8);
    write_all(fd, req, sizeof(req));
    uint64_t reply = 0;
    if (read_exact(fd, &reply, sizeof(reply)) != (ssize_t)sizeof(reply) || reply != ~r->token) {
        die("fresh reply mismatch");
    }
    r->elapsed_ns = now_ns() - r->target_ns;
    close(fd);
    return NULL;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static void print_bins(const char *name, const uint64_t bins[12]) {
    printf("\"%s\":[", name);
    for (int i = 0; i < 12; ++i) printf("%s%llu", i ? "," : "", (unsigned long long)bins[i]);
    putchar(']');
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 6;
    if (seconds < 1 || seconds > 30) seconds = 6;
    signal(SIGPIPE, SIG_IGN);
    alarm((unsigned)seconds + 30);
    for (size_t i = 0; i < BLOCK_BYTES; ++i) g_payload[i] = (unsigned char)(i * 31 + 7);

    // 1. Start backend TCP server on ephemeral loopback port.
    g_backend_listen = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(g_backend_listen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in bsa = {
        .sin_len = sizeof(bsa), .sin_family = AF_INET,
        .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (bind(g_backend_listen, (struct sockaddr *)&bsa, sizeof(bsa)) < 0 ||
        listen(g_backend_listen, SOMAXCONN) < 0) die("backend listen");
    socklen_t blen = sizeof(bsa);
    getsockname(g_backend_listen, (struct sockaddr *)&bsa, &blen);
    g_backend_port = ntohs(bsa.sin_port);

    pthread_t backend_tid;
    if (pthread_create(&backend_tid, NULL, backend_accept_loop, NULL) != 0) die("backend thread");

    // 2. Start relay (1 accept owner + 2 data workers).
    struct relay_owner accept_owner = {0};
    struct relay_owner workers[WORKERS] = {0};
    start_relay_owner(&accept_owner, 0);
    for (int i = 0; i < WORKERS; ++i) start_relay_owner(&workers[i], WORKERS);

    struct relay_lease lease = { .owners = workers };
    struct relay_lease *lp = &lease;
    struct relay_owner *wp = workers;
    mp_tcp_relay *accept_relay = accept_owner.relay;
    dispatch_sync(accept_owner.queue, ^{
        lp->listener = mp_tcp_listen(accept_relay, 0, g_backend_port, &g_relay_port, 1);
        if (!lp->listener) die("mp_tcp_listen");
        for (int i = 0; i < WORKERS; ++i) {
            lp->targets[i] = mp_tcp_target(wp[i].relay, lp->listener);
            if (!lp->targets[i]) die("mp_tcp_target");
        }
        mp_tcp_set_handoff(lp->listener, on_handoff, lp);
    });

    // 3. Start 32 bulk download streams and warm up.
    struct bulk_client bulks[BULK_STREAMS] = {0};
    for (int i = 0; i < BULK_STREAMS; ++i) {
        if (pthread_create(&bulks[i].thread, NULL, bulk_client_thread, &bulks[i]) != 0) die("bulk thread");
    }
    for (int i = 0; i < BULK_STREAMS; ++i) {
        while (atomic_load_explicit(&bulks[i].bytes, memory_order_relaxed) < 2 * BLOCK_BYTES) usleep(1000);
    }

    // 4. Score 40 fresh req/s for `seconds` seconds while 32 bulk streams saturate the relay.
    int count = seconds * 40;
    struct fresh_req *reqs = calloc((size_t)count, sizeof(*reqs));
    uint64_t before[BULK_STREAMS];
    for (int i = 0; i < BULK_STREAMS; ++i) before[i] = atomic_load_explicit(&bulks[i].bytes, memory_order_relaxed);
    uint64_t cpu0 = proc_cpu_us();
    uint64_t t0 = now_ns();
    for (int i = 0; i < count; ++i) {
        uint64_t target = t0 + (uint64_t)i * FRESH_PERIOD_NS;
        for (;;) {
            uint64_t now = now_ns();
            if (now >= target) break;
            uint64_t left = target - now;
            struct timespec ts = { (time_t)(left / 1000000000ULL), (long)(left % 1000000000ULL) };
            nanosleep(&ts, NULL);
        }
        reqs[i].token = 0xCAFE000000000000ULL | (uint64_t)(i + 1);
        reqs[i].target_ns = target;
        if (pthread_create(&reqs[i].thread, NULL, fresh_req_thread, &reqs[i]) != 0) die("fresh thread");
    }
    // Wait until window end.
    uint64_t end_target = t0 + (uint64_t)count * FRESH_PERIOD_NS;
    while (now_ns() < end_target) usleep(1000);
    uint64_t elapsed_ns = now_ns() - t0;
    uint64_t cpu1 = proc_cpu_us();
    uint64_t total_bytes = 0;
    for (int i = 0; i < BULK_STREAMS; ++i) {
        total_bytes += atomic_load_explicit(&bulks[i].bytes, memory_order_relaxed) - before[i];
    }
    for (int i = 0; i < count; ++i) pthread_join(reqs[i].thread, NULL);

    // 5. Stop cleanly and harvest stats.
    atomic_store_explicit(&g_stop, true, memory_order_relaxed);
    for (int i = 0; i < BULK_STREAMS; ++i) pthread_join(bulks[i].thread, NULL);
    close(g_backend_listen);
    pthread_join(backend_tid, NULL);

    __block mp_tcp_stats stats = {0};
    dispatch_sync(accept_owner.queue, ^{
        for (int i = 0; i < WORKERS; ++i) {
            mp_tcp_listener *target = lp->targets[i];
            dispatch_sync(wp[i].queue, ^{ mp_tcp_release(target, NULL); });
        }
        mp_tcp_release(lp->listener, &stats);
    });
    for (int i = 0; i < WORKERS; ++i) stop_relay_owner(&workers[i]);
    stop_relay_owner(&accept_owner);

    uint64_t *lat = malloc((size_t)count * sizeof(*lat));
    for (int i = 0; i < count; ++i) lat[i] = reqs[i].elapsed_ns;
    qsort(lat, (size_t)count, sizeof(*lat), cmp_u64);
    double mib_s = ((double)total_bytes / (1024.0 * 1024.0)) / ((double)elapsed_ns / 1e9);
    double cpu_s_gib = ((double)(cpu1 - cpu0) / 1e6) / ((double)total_bytes / (1024.0 * 1024.0 * 1024.0));
    printf("{\"mode\":\"%s\",\"bulk_mib_s\":%.1f,\"cpu_s_per_gib\":%.4f,"
           "\"fresh_p50_us\":%.1f,\"fresh_p95_us\":%.1f,\"fresh_p99_us\":%.1f,"
           "\"accepted\":%llu,\"connected\":%llu,\"connect_errors\":%llu,",
#ifdef LEGACY_GCD_HANDOFF
           "legacy-gcd",
#else
           "lockfree-evfilt-user",
#endif
           mib_s, cpu_s_gib,
           (double)lat[count / 2] / 1000.0,
           (double)lat[(count * 95 - 1) / 100] / 1000.0,
           (double)lat[(count * 99 - 1) / 100] / 1000.0,
           (unsigned long long)stats.accepted,
           (unsigned long long)stats.connected,
           (unsigned long long)stats.connect_errors);
    print_bins("enqueue_to_adopt_us", stats.handoff.enqueue_to_adopt_us);
    putchar(',');
    print_bins("connect_us", stats.connect_us);
    putchar(',');
    print_bins("first_byte_us", stats.first_byte_us);
    puts("}");

    free(lat);
    free(reqs);
    return 0;
}
