// Time one queued handoff during an eight-stream burst using real dispatch source wakes.
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>

enum { STREAMS = 8, OFFER = 1024 * 1024 };
static int client[STREAMS+1][2], guest[STREAMS+1][2];
static unsigned char body[STREAMS][OFFER];
static unsigned char marker;
static dispatch_queue_t queue;
static dispatch_semaphore_t installed, cancelled;
static unsigned trigger, writes, callbacks;
static bool scoring;
static uint64_t enqueued, entered, marker_received, callback_cpu;
static void queue_handoff(void);

static uint64_t clock_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static ssize_t record_bulk_write(int fd, const void *data, size_t size) {
    ssize_t n = write(fd, data, size);
    if (scoring && n > 0) {
        for (unsigned i = 0; i < STREAMS; i++) {
            if (fd == client[i][1]) {
                if (++writes == trigger) queue_handoff();
                break;
            }
        }
    }
    return n;
}

#define write(...) record_bulk_write(__VA_ARGS__)
#define main filter_work_main
#include "filter_work.c"
#undef main
#undef write

static mp_tcp_relay *owner;
static mp_tcp_listener *lease;

static void handoff(void *unused) {
    (void)unused;
    entered = clock_ns();
#if YIELD_ON_HANDOFF
    mp_tcp_handoff_started(owner);
#endif
    stage(lease, client[STREAMS], guest[STREAMS]);
    check(fcntl(client[STREAMS][0], F_SETFL, 0) == 0, "blocking marker receiver");
    check(write(guest[STREAMS][0], &marker, 1) == 1, "offer server-first reply");
    dispatch_semaphore_signal(installed);
}

static void queue_handoff(void) {
    enqueued = clock_ns();
#if YIELD_ON_HANDOFF
    mp_tcp_handoff_enqueued(owner);
#endif
    dispatch_async_f(queue, NULL, handoff);
}

static void wake(void *unused) {
    (void)unused;
    check(qos_class_self() == QOS_CLASS_USER_INITIATED, "data-owner QoS");
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    mp_tcp_relay_drain(owner, 2);
    callback_cpu += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    callbacks++;
}

static void did_cancel(void *unused) {
    (void)unused;
    dispatch_semaphore_signal(cancelled);
}

static void *receive_marker(void *unused) {
    (void)unused;
    dispatch_semaphore_wait(installed, DISPATCH_TIME_FOREVER);
    unsigned char byte;
    check(read(client[STREAMS][0], &byte, 1) == 1 && byte == marker, "verified marker");
    marker_received = clock_ns();
    return NULL;
}

static void room(int fd[2]) {
    int bytes = OFFER;
    for (int end = 0; end < 2; end++) {
        check(setsockopt(fd[end], SOL_SOCKET, SO_SNDBUF, &bytes, sizeof(bytes)) == 0 &&
              setsockopt(fd[end], SOL_SOCKET, SO_RCVBUF, &bytes, sizeof(bytes)) == 0, "socket room");
    }
}

static void verify_burst(unsigned flow) {
    unsigned char buf[65536];
    for (unsigned at = 0; at < OFFER;) {
        size_t want = OFFER - at < sizeof(buf) ? OFFER - at : sizeof(buf);
        ssize_t n = read(client[flow][0], buf, want);
        check(n > 0 && !memcmp(buf, body[flow] + at, (size_t)n), "bulk receiver bytes");
        at += (unsigned)n;
    }
}

static void wave(unsigned position, unsigned sequence) {
    writes = callbacks = 0;
    entered = enqueued = marker_received = callback_cpu = 0;
    scoring = false;
    trigger = position;
    marker = (unsigned char)(1 + sequence);
    owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner && mp_tcp_data_callback_events(2) == 128 && mp_tcp_relay_read_bytes(owner) == 262144,
          "data owner and controls");
    lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "lease");
    for (unsigned i = 0; i < STREAMS; i++) {
        stage(lease, client[i], guest[i]);
        room(client[i]);
        room(guest[i]);
        check(fcntl(client[i][0], F_SETFL, 0) == 0, "blocking bulk receiver");
        body[i][0] = (unsigned char)(sequence + i);
    }
    drain(owner);
    for (unsigned i = 0; i < STREAMS; i++)
        check(write(guest[i][0], body[i], LARGE_READ) == LARGE_READ, "prime bulk");
    drain(owner);
    for (unsigned i = 0; i < STREAMS; i++) {
        expect_bytes(client[i][0], body[i], LARGE_READ);
        check(write(guest[i][0], body[i], OFFER) == OFFER, "queue complete burst");
    }
    installed = dispatch_semaphore_create(0);
    cancelled = dispatch_semaphore_create(0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, owner->kq, 0, queue);
    check(installed && cancelled && source, "dispatch objects");
    dispatch_source_set_event_handler_f(source, wake);
    dispatch_source_set_cancel_handler_f(source, did_cancel);
    pthread_t reader;
    check(pthread_create(&reader, NULL, receive_marker, NULL) == 0, "marker reader");
    scoring = true;
    uint64_t start = clock_ns();
    dispatch_resume(source);
    for (unsigned i = 0; i < STREAMS; i++) verify_burst(i);
    uint64_t end = clock_ns();
    check(!pthread_join(reader, NULL), "join marker reader");
    dispatch_source_cancel(source);
    dispatch_semaphore_wait(cancelled, DISPATCH_TIME_FOREVER);
    scoring = false;
    check(start <= enqueued && enqueued <= entered && entered <= marker_received &&
          callbacks && writes == STREAMS * OFFER / 262144, "wave tracking");

    for (int i = 0; i <= STREAMS; i++) check(!shutdown(guest[i][0], SHUT_WR), "guest FIN");
    drain(owner);
    for (int i = 0; i <= STREAMS; i++) {
        unsigned char byte;
        check(read(client[i][0], &byte, 1) == 0 && write(client[i][0], &marker, 1) == 1 &&
              !shutdown(client[i][0], SHUT_WR), "reverse marker and FIN");
    }
    drain(owner);
    for (int i = 0; i <= STREAMS; i++) {
        unsigned char byte;
        expect_bytes(guest[i][0], &marker, 1);
        check(read(guest[i][0], &byte, 1) == 0, "ordered EOF");
        close(client[i][0]); close(guest[i][0]);
    }
    check(lease->active == 0 && !lease->head, "all pairs retired");
    printf("{\"position\":%u,\"bytes\":%u,\"bulk_ns\":%llu,\"queue_ns\":%llu,\"reply_ns\":%llu,"
           "\"callback_cpu_ns\":%llu,\"callbacks\":%u,\"half_closes\":%u}\n",
           trigger, STREAMS*OFFER, end-start, entered-enqueued, marker_received-enqueued,
           callback_cpu, callbacks, 2*(STREAMS+1));
    fflush(stdout);
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    dispatch_release(source);
    dispatch_release(installed);
    dispatch_release(cancelled);
}

int main(int argc, char **argv) {
    check(argc > 1, "supply the handoff positions");
    signal(SIGPIPE, SIG_IGN);
    alarm(30);
    for (unsigned i = 0; i < STREAMS; i++)
        for (unsigned j = 0; j < OFFER; j++)
            body[i][j] = (unsigned char)(i*61 + j*17 + j/251);
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                         QOS_CLASS_USER_INITIATED, 0);
    queue = dispatch_queue_create("micropod.fixture.handoff-timing", attr);
    for (int arg = 1; arg < argc; arg++) {
        int position = atoi(argv[arg]);
        check(position >= 1 && position <= 32, "handoff position");
        wave((unsigned)position, (unsigned)arg);
    }
    dispatch_release(queue);
}
