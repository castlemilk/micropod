// Exercise a single native kqueue data owner with 16 already-classified guest streams.
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/event.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { FLOWS = 16, SMALL = 128 * 1024, DEEP = 384 * 1024, TOTAL = 4 * 1024 * 1024 };
static int clients[FLOWS+1][2], guests[FLOWS+1][2];
static unsigned lengths[FLOWS], donor, salt;
static unsigned char bodies[FLOWS][DEEP], marker;
static uint64_t offered_at, received_at, owner_ns;
static unsigned reads, writes, large_reads, callbacks, polls, poll_n, poll_bytes, max_poll_bytes;
static bool timing, use_credit;
static dispatch_queue_t queue;
static dispatch_semaphore_t reading, cancelled;

static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void validate_poll(void) {
    if (poll_bytes > poll_n * 262144u) abort();
    if (poll_bytes > max_poll_bytes) max_poll_bytes = poll_bytes;
}
static int trace_poll(int fd, const struct kevent *changes, int nc, struct kevent *events,
                      int cap, const struct timespec *timeout) {
    if (timing && cap) validate_poll();
    int n = kevent(fd, changes, nc, events, cap, timeout);
    if (timing && cap) {
        if (n > 0) polls++;
        poll_n = n > 0 ? (unsigned)n : 0;
        poll_bytes = 0;
    }
    return n;
}
static ssize_t trace_read(int fd, void *buf, size_t size) {
    ssize_t n = read(fd, buf, size);
    if (timing && n > 1) {
        reads++;
        large_reads += n > 262144;
        poll_bytes += (unsigned)n;
    }
    return n;
}
static ssize_t trace_write(int fd, const void *buf, size_t size) {
    ssize_t n = write(fd, buf, size);
    if (timing && n > 1) {
        writes++;
        if (fd == clients[donor][1] && !offered_at) {
            offered_at = now();
            if (write(guests[FLOWS][0], &marker, 1) != 1) abort();
        }
    }
    return n;
}
#define BENCH_POLL_READ_CREDIT use_credit
#define FIXTURE_KEVENT trace_poll
#define read(...) trace_read(__VA_ARGS__)
#define write(...) trace_write(__VA_ARGS__)
#define main filter_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef write

static mp_tcp_relay *owner;
static void wake(void *unused) {
    (void)unused;
    check(qos_class_self() == QOS_CLASS_USER_INITIATED, "data owner QoS");
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    mp_tcp_relay_drain(owner, 2);
    owner_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    callbacks++;
}
static void end_wakes(void *unused) { (void)unused; dispatch_semaphore_signal(cancelled); }
static void *watch_reply(void *unused) {
    (void)unused;
    dispatch_semaphore_signal(reading);
    unsigned char byte;
    check(read(clients[FLOWS][0], &byte, 1) == 1 && byte == marker, "short reply");
    received_at = now();
    return NULL;
}
static void room(int ends[2]) {
    int size = DEEP;
    for (int j=0; j<2; j++)
        check(!setsockopt(ends[j], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) &&
              !setsockopt(ends[j], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)), "socket capacity");
}
static void verify(unsigned flow) {
    unsigned char buf[64*1024];
    for (unsigned at=0; at<lengths[flow];) {
        size_t want = lengths[flow]-at < sizeof(buf) ? lengths[flow]-at : sizeof(buf);
        ssize_t n = read(clients[flow][0], buf, want);
        check(n>0 && !memcmp(buf, bodies[flow]+at, (size_t)n), "bulk receiver payload");
        at += (unsigned)n;
    }
}
static void wave(unsigned layout) {
    const unsigned parity = layout % 2;
    donor = 2 * (layout/2) + parity;
    reads = writes = large_reads = callbacks = polls = poll_n = poll_bytes = max_poll_bytes = 0;
    offered_at = received_at = owner_ns = 0;
    marker = (unsigned char)(++salt);
    owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "data owner");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "lease");
    for (unsigned i=0; i<=FLOWS; i++) {
        stage(lease, clients[i], guests[i]);
        room(clients[i]); room(guests[i]);
        check(!fcntl(clients[i][0], F_SETFL, 0), "blocking verification socket");
        if (i < FLOWS) {
            lengths[i] = i%2 == parity ? SMALL : DEEP;
            bodies[i][0] = (unsigned char)(salt + i);
        }
    }
    drain(owner);
    for (unsigned i=0; i<FLOWS; i++)
        check(write(guests[i][0], bodies[i], LARGE_READ) == LARGE_READ, "classify bulk");
    drain(owner);
    for (unsigned i=0; i<FLOWS; i++) {
        expect_bytes(clients[i][0], bodies[i], LARGE_READ);
        check(write(guests[i][0], bodies[i], lengths[i]) == lengths[i], "offer burst");
    }
    reading = dispatch_semaphore_create(0);
    cancelled = dispatch_semaphore_create(0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, owner->kq, 0, queue);
    check(reading && cancelled && source, "dispatch sources");
    dispatch_source_set_event_handler_f(source, wake);
    dispatch_source_set_cancel_handler_f(source, end_wakes);
    pthread_t watcher;
    check(!pthread_create(&watcher, NULL, watch_reply, NULL), "short receiver");
    dispatch_semaphore_wait(reading, DISPATCH_TIME_FOREVER);
    timing = true;
    uint64_t start = now();
    dispatch_resume(source);
    for (unsigned i=0; i<FLOWS; i++) verify(i);
    uint64_t end = now();
    check(!pthread_join(watcher,NULL), "join short receiver");
    dispatch_source_cancel(source);
    dispatch_semaphore_wait(cancelled, DISPATCH_TIME_FOREVER);
    timing = false;
    validate_poll();
    check(offered_at >= start && received_at > offered_at && callbacks && polls > 0 &&
          reads >= FLOWS && reads == writes && (!use_credit ? !large_reads : true), "wave measurements");
    for (int i=0; i<=FLOWS; i++) check(!shutdown(guests[i][0], SHUT_WR),"guest FIN");
    drain(owner);
    for (int i=0; i<=FLOWS; i++) {
        unsigned char byte;
        check(read(clients[i][0], &byte, 1) == 0 && write(clients[i][0], &marker, 1) == 1 &&
              !shutdown(clients[i][0], SHUT_WR), "reverse marker and FIN");
    }
    drain(owner);
    for (int i=0; i<=FLOWS; i++) {
        unsigned char byte;
        expect_bytes(guests[i][0], &marker, 1);
        check(read(guests[i][0], &byte, 1) == 0, "ordered EOF");
        close(guests[i][0]);close(clients[i][0]);
    }
    check(!lease->active && !lease->head, "retire all flows");
    printf("{\"layout\":%u,\"bytes\":%u,\"bulk_ns\":%llu,\"reply_ns\":%llu,\"owner_ns\":%llu,"
           "\"reads\":%u,\"writes\":%u,\"above_cap_reads\":%u,\"polls\":%u,\"max_poll_bytes\":%u,"
           "\"callbacks\":%u,\"markers\":1,\"half_closes\":%u}\n", layout,TOTAL,end-start,
           received_at-offered_at,owner_ns,reads,writes,large_reads,polls,max_poll_bytes,callbacks,2*(FLOWS+1));
    fflush(stdout);
    mp_tcp_release(lease,NULL); mp_tcp_relay_destroy(owner);
    dispatch_release(source);dispatch_release(reading);dispatch_release(cancelled);
}
int main(int argc, char **argv) {
    check(argc > 2 && (!strcmp(argv[1],"stock") || !strcmp(argv[1],"credit")), "expected stock|credit and layouts");
    use_credit = !strcmp(argv[1],"credit");
    alarm(30); signal(SIGPIPE,SIG_IGN);
    for(unsigned i=0;i<FLOWS;i++)
        for(unsigned j=0;j<DEEP;j++) bodies[i][j]=(unsigned char)(i*31 + j*17 + j/251);
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
    queue=dispatch_queue_create("micropod.fixture.poll-credit",attr);
    for(int j=2;j<argc;j++) {
        int layout=atoi(argv[j]);check(layout>=0 && layout<16,"layout");wave((unsigned)layout);
    }
    dispatch_release(queue);
}
