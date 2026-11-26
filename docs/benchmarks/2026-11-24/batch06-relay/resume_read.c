// Observe real data-owner poll and read work after pressure clears.
#include <sys/event.h>
#include <fcntl.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

enum { MAX_BULK = 8, BLOCK = 32768 };
static int client_fd[MAX_BULK], guest_fd[MAX_BULK], bulk, fresh_fd, fresh_sender;
static bool measure;
static size_t progressed, ahead;
static unsigned poll_no, first_next_block_poll, fresh_poll, read_calls, empty_reads;
static unsigned char fresh_byte = 193;

static int observed_poll(int fd, const struct kevent *change, int nchange, struct kevent *events,
                         int capacity, const struct timespec *timeout) {
    int n = kevent(fd, change, nchange, events, capacity, timeout);
    if (measure && !nchange && n > 0) poll_no++;
    return n;
}
static ssize_t observed_read(int fd, void *data, size_t len) {
    ssize_t n = read(fd, data, len);
    if (measure) for (int i=0; i<bulk; i++) if (fd == guest_fd[i]) {
        read_calls++; empty_reads += n < 0 && errno == EAGAIN;
        break;
    }
    return n;
}
static ssize_t observed_write(int fd, const void *data, size_t len) {
    ssize_t n = write(fd, data, len);
    if (!measure || n <= 0) return n;
    if (fd == fresh_fd) {
        if (n != 1 || *(const unsigned char *)data != fresh_byte || fresh_poll) _exit(2);
        ahead = progressed; fresh_poll = poll_no;
        return n;
    }
    for (int i=0; i<bulk; i++) if (fd == client_fd[i]) {
        if (progressed == 0 && write(fresh_sender, &fresh_byte, 1) != 1) _exit(2);
        if (n == BLOCK && !first_next_block_poll) first_next_block_poll = poll_no;
        progressed += (size_t)n;
        break;
    }
    return n;
}
#define FIXTURE_KEVENT observed_poll
#define read(...) observed_read(__VA_ARGS__)
#define write(...) observed_write(__VA_ARGS__)
#define main existing_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef write

static unsigned char offer[MAX_BULK][BLOCK];
static void cell(int nbulk, bool queued) {
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create owner");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "create lease");
    struct pair *streams[MAX_BULK+1];
    int c[MAX_BULK+1][2], g[MAX_BULK+1][2];
    size_t padding_bytes[MAX_BULK];
    bulk = nbulk;
    for (int i=0; i<=bulk; i++) streams[i]=stage(lease,c[i],g[i]);
    drain(owner);
    for (int i=0; i<bulk; i++) {
        guest_fd[i] = g[i][1]; client_fd[i] = c[i][1];
        for (size_t k=0; k<BLOCK; k++) offer[i][k]=(unsigned char)(k*13+i*5);
        check(write(g[i][0], offer[i], BLOCK) == BLOCK, "prime bulk direction");
    }
    drain(owner);
    for (int i=0; i<bulk; i++) {
        expect_bytes(c[i][0],offer[i],BLOCK);
        check(streams[i]->guest.bulk_read, "classified bulk");
        padding_bytes[i]=fill(c[i][1]);
        check(write(g[i][0],offer[i],17)==17, "offer short suffix");
    }
    drain(owner);
    for (int i=0; i<bulk; i++) {
        check(streams[i]->client.pending && streams[i]->client.length==17, "actual backpressure");
        if (queued) check(write(g[i][0],offer[i],BLOCK)==BLOCK, "offer following block");
        consume_padding(c[i][0], padding_bytes[i]);
    }
    fresh_fd=c[bulk][1]; fresh_sender=g[bulk][0];
    progressed=ahead=0;
    poll_no=first_next_block_poll=fresh_poll=read_calls=empty_reads=0;
    measure=true; drain(owner); measure=false;
    size_t expected=(size_t)bulk*(17+(queued ? BLOCK:0));
    check(progressed==expected && fresh_poll!=0 && (!queued || first_next_block_poll!=0), "delivery counts");
    for (int i=0; i<bulk; i++) {
        expect_bytes(c[i][0],offer[i],17);
        if (queued) expect_bytes(c[i][0],offer[i],BLOCK);
    }
    expect_bytes(c[bulk][0],&fresh_byte,1);
    for (int i=0; i<=bulk; i++) check(shutdown(g[i][0],SHUT_WR)==0,"guest FIN");
    drain(owner);
    for (int i=0; i<=bulk; i++) {
        unsigned char unused;
        check(read(c[i][0],&unused,1)==0 && write(c[i][0],&fresh_byte,1)==1 &&
              shutdown(c[i][0],SHUT_WR)==0,"forward FIN and reverse reply");
    }
    drain(owner);
    for (int i=0; i<=bulk; i++) {
        unsigned char unused;
        expect_bytes(g[i][0],&fresh_byte,1);
        check(read(g[i][0],&unused,1)==0,"reverse FIN");
        close(c[i][0]); close(g[i][0]);
    }
    check(!lease->active && !lease->head,"retired");
    printf("{\"stalled_streams\":%d,\"next_bytes_per_source\":%d,\"bulk_delivered\":%zu,"
           "\"bulk_ahead_of_fresh\":%zu,\"fresh_poll\":%u,\"first_followup_block_poll\":%u,"
           "\"nonempty_polls\":%u,\"guest_read_calls\":%u,\"empty_guest_reads\":%u,"
           "\"verified_fresh_replies\":1,\"streams_retired\":%d}\n",
           bulk,queued ? BLOCK:0,progressed,ahead,fresh_poll,first_next_block_poll,poll_no,
           read_calls,empty_reads,bulk+1);
    mp_tcp_release(lease,NULL); mp_tcp_relay_destroy(owner);
}
int main(void) {
    for (int n=1; n<=8; n*=2) {
        cell(n,false); cell(n,true);
    }
    return 0;
}
