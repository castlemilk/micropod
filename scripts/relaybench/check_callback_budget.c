// Turn 160 queued bytes into 160 ready-stream events in the real Darwin drain.
// The one-byte read limit applies only to this fixed-work configuration check.
#include <sys/ioctl.h>
#include <unistd.h>

static ssize_t read_one(int fd, void *buf, size_t length) {
    return read(fd, buf, length > 1 ? 1 : length);
}

#define read(...) read_one(__VA_ARGS__)
#include "../../Sources/CPublishedTCP/PublishedTCP.c"
#undef read

static void check(bool ok, const char *action) {
    if (!ok) { fprintf(stderr, "%s (errno %d)\n", action, errno); exit(1); }
}

static void run(int workers, int expected) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    struct pair *p = calloc(1, sizeof(*p));
    int client[2], guest[2];
    check(l && p && socketpair(AF_UNIX, SOCK_STREAM, 0, client) == 0 &&
          socketpair(AF_UNIX, SOCK_STREAM, 0, guest) == 0, "connected stream");
    check(fcntl(client[1], F_SETFL, O_NONBLOCK) == 0 && fcntl(guest[1], F_SETFL, O_NONBLOCK) == 0,
          "nonblocking relay");
    p->listener = l;
    l->head = p;
    l->active = 1;
    p->client = (struct endpoint){ .watch = { STREAM, client[1] }, .pair = p };
    p->guest = (struct endpoint){ .watch = { STREAM, guest[1] }, .pair = p };
    check(watch_fd(r, &p->client.watch, EVFILT_READ, EV_ADD) == 0, "register stream");
    unsigned char data[160], received[sizeof(data)];
    for (size_t i = 0; i < sizeof(data); ++i) data[i] = (unsigned char)i;
    check(write(client[0], data, sizeof(data)) == sizeof(data), "queue payload");
    mp_tcp_relay_drain(r, workers);
    int available;
    check(ioctl(guest[0], FIONREAD, &available) == 0, "read queued count");
    printf("%d workers: readback=%d events, forwarded in one callback=%d bytes\n",
           workers, mp_tcp_data_callback_events(workers), available);
    check(available == expected && mp_tcp_data_callback_events(workers) == expected, "unexpected drain budget");
    for (int done = expected; done < (int)sizeof(data); done += expected) mp_tcp_relay_drain(r, workers);
    check(recv(guest[0], received, sizeof(received), MSG_WAITALL) == sizeof(received) &&
          memcmp(data, received, sizeof(data)) == 0, "verify remaining callbacks and byte order");
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    close(client[0]);
    close(guest[0]);
}

int main(int argc, char **argv) {
    check(argc == 2 && (!strcmp(argv[1], "stock") || !strcmp(argv[1], "fixed")), "expected stock or fixed");
    alarm(5);
    run(2, 128);
    run(4, !strcmp(argv[1], "fixed") ? 128 : 24);
    return 0;
}
