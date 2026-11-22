#include "PublishedTCP.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/tcp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

// One scratch buffer per worker. Only a short write needs per-stream storage.
#define CHUNK (256 * 1024)
#define EVENTS_PER_TURN 128
#define INTERACTIVE_BULK_BATCH 2
#define THROUGHPUT_BULK_BATCH 12
#define DATA_READY_BATCH 24
#define LARGE_READ (16 * 1024)

enum event_kind { ACCEPT, STREAM, BULK_READY, RETRY_GUEST };
struct watch { enum event_kind kind; int fd; };
struct pair;

struct mp_tcp_relay {
    int kq;
    struct watch bulk;
    struct in_addr guest, gateway;
    unsigned ifindex;
    unsigned next_first_worker;
    int guest_receive_buffer;
    atomic_bool path_failure, guest_data;
    uint64_t interface_checked;
    struct pair *retired;
    char scratch[CHUNK];
};

struct mp_tcp_listener {
    struct watch watch;
    mp_tcp_relay *relay;
    struct sockaddr_in target;
    struct pair *head;
    mp_tcp_handoff handoff;
    void *owner;
    mp_tcp_listener *parent;
    atomic_uint group_active, group_peak;
    unsigned active;
    unsigned next_worker;
    uint64_t last_error_at;
    bool profile, retry_accept, assigned_worker;
    mp_tcp_stats stats;
};

struct endpoint {
    struct watch watch;
    struct pair *pair;
    bool connecting, eof, bulk_read;
    uint16_t close_flags;
    uint32_t close_fflags;
    int64_t close_data;
    char *pending;
    size_t offset, length;
};

struct pair {
    mp_tcp_listener *listener;
    struct pair *prev, *next;
    struct endpoint client, guest;
    struct watch retry;
    bool retry_pending, retried, early_close_seen, guest_replied;
    uint16_t client_port;
    uint64_t deadline;
    uint64_t accepted_at, connected_at, first_request_write_at;
};

static struct kevent filter_change(struct watch *w, int16_t filter, uint16_t flags) {
    struct kevent change;
    EV_SET(&change, w->fd, filter, flags, 0, 0, w);
    return change;
}

static int submit_changes(int kq, const struct kevent *changes, int count) {
    int status;
    do { status = kevent(kq, changes, count, NULL, 0, NULL); } while (status < 0 && errno == EINTR);
    return status;
}

static int change_watch(int kq, struct watch *w, int16_t filter, uint16_t flags) {
    struct kevent change = filter_change(w, filter, flags);
    return submit_changes(kq, &change, 1);
}

static struct endpoint *opposite(struct endpoint *e) {
    return e == &e->pair->client ? &e->pair->guest : &e->pair->client;
}

static int watch_queue(mp_tcp_relay *r, struct watch *w, int16_t filter) {
    int q = r->kq;
    if (r->bulk.fd >= 0 && w->kind == STREAM) {
        struct endpoint *e = (struct endpoint *)w;
        // READ consumes this direction; WRITE flushes its peer's pending bytes.
        if ((filter == EVFILT_READ ? e : opposite(e))->bulk_read) q = r->bulk.fd;
    }
    return q;
}

static int watch_fd(mp_tcp_relay *r, struct watch *w, int16_t filter, uint16_t flags) {
    return change_watch(watch_queue(r, w, filter), w, filter, flags);
}

static int update_stream_filters(mp_tcp_relay *r, const struct kevent *changes, int count) {
#if defined(MICROPOD_BATCH_STREAM_FILTERS) && MICROPOD_BATCH_STREAM_FILTERS
    // Dedicated data owners use one kqueue. These ADD/ENABLE/DISABLE
    // operations are idempotent on EINTR. The caller closes both descriptors
    // on error, which also removes any prefix the kernel already installed.
    if (r->bulk.fd < 0) return submit_changes(r->kq, changes, count);
#endif
    for (int i = 0; i < count; ++i) {
        int q = watch_queue(r, changes[i].udata, changes[i].filter);
        if (submit_changes(q, &changes[i], 1) < 0) return -1;
    }
    return 0;
}

static int prepare(int fd) {
    int one = 1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ||
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) < 0) return -1;
    return 0;
}

static mp_tcp_relay *create_relay(const char *guest, bool data_only) {
    struct in_addr address;
    if (inet_pton(AF_INET, guest, &address) != 1) { errno = EINVAL; return NULL; }
    mp_tcp_relay *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->guest = address;
    atomic_init(&r->path_failure, false);
    atomic_init(&r->guest_data, false);
    r->kq = kqueue();
    r->bulk = (struct watch){ BULK_READY, data_only ? -1 : kqueue() };
    if (r->kq < 0 || fcntl(r->kq, F_SETFD, FD_CLOEXEC) < 0 ||
        (!data_only && (r->bulk.fd < 0 || fcntl(r->bulk.fd, F_SETFD, FD_CLOEXEC) < 0 ||
                        watch_fd(r, &r->bulk, EVFILT_READ, EV_ADD) < 0))) {
        int err = errno;
        if (r->kq >= 0) close(r->kq);
        if (r->bulk.fd >= 0) close(r->bulk.fd);
        free(r);
        errno = err;
        return NULL;
    }
    return r;
}

mp_tcp_relay *mp_tcp_relay_create(const char *guest) { return create_relay(guest, false); }

mp_tcp_relay *mp_tcp_relay_create_data(const char *guest) { return create_relay(guest, true); }

void mp_tcp_relay_bound_guest_window(mp_tcp_relay *r) {
    // Keep macOS receive autotuning from admitting several MiB per stream
    // into the same guest virtio TX queue when many downloads start together.
    r->guest_receive_buffer = 512 * 1024;
}

int mp_tcp_relay_scope(mp_tcp_relay *r, const char *gateway) {
    struct in_addr address;
    if (inet_pton(AF_INET, gateway, &address) != 1 || !address.s_addr) { errno = EINVAL; return -1; }
    r->gateway = address;
    r->ifindex = 0;
    r->interface_checked = 0;
    return 0;
}

// The ifindex can change when vmnet rematerializes a worker's bridge. Cache
// successful lookups briefly; bind the source address on every connection.
static int scope_guest(mp_tcp_relay *r, int fd) {
    if (!r->gateway.s_addr) return 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t ttl = r->ifindex ? 1000000000ULL : 100000000ULL;
    if (!r->interface_checked || now - r->interface_checked >= ttl) {
        struct ifaddrs *all;
        if (getifaddrs(&all) < 0) return -1;
        r->ifindex = 0;
        for (struct ifaddrs *a = all; a; a = a->ifa_next) {
            if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) &&
                ((struct sockaddr_in *)a->ifa_addr)->sin_addr.s_addr == r->gateway.s_addr) {
                r->ifindex = if_nametoindex(a->ifa_name);
                break;
            }
        }
        freeifaddrs(all);
        r->interface_checked = now;
    }
    if (!r->ifindex) { errno = EADDRNOTAVAIL; return -1; }
    struct sockaddr_in source = { .sin_len = sizeof(source), .sin_family = AF_INET, .sin_addr = r->gateway };
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &r->ifindex, sizeof(r->ifindex)) < 0 ||
        bind(fd, (struct sockaddr *)&source, sizeof(source)) < 0) { r->ifindex = 0; return -1; }
    return 0;
}

int mp_tcp_take_path_failure(mp_tcp_relay *r) {
    return atomic_exchange_explicit(&r->path_failure, false, memory_order_relaxed);
}

int mp_tcp_take_guest_data(mp_tcp_relay *r) {
    return atomic_exchange_explicit(&r->guest_data, false, memory_order_relaxed);
}

int mp_tcp_relay_descriptor(const mp_tcp_relay *r) { return r->kq; }

static mp_tcp_listener *new_listener(mp_tcp_relay *r, uint16_t guest, int profile) {
    if (guest < 1024) { errno = EINVAL; return NULL; }
    mp_tcp_listener *l = calloc(1, sizeof(*l));
    if (!l) return NULL;
    atomic_init(&l->group_active, 0);
    atomic_init(&l->group_peak, 0);
    l->watch = (struct watch){ ACCEPT, -1 };
    l->relay = r;
    l->profile = profile != 0;
    l->target = (struct sockaddr_in){ .sin_len = sizeof(l->target), .sin_family = AF_INET,
        .sin_port = htons(guest), .sin_addr = r->guest };
    return l;
}

mp_tcp_listener *mp_tcp_target(mp_tcp_relay *r, mp_tcp_listener *parent) {
    mp_tcp_listener *l = new_listener(r, ntohs(parent->target.sin_port), parent->profile);
    if (l) l->parent = parent;
    return l;
}

void mp_tcp_set_handoff(mp_tcp_listener *l, mp_tcp_handoff handler, void *owner) {
    l->handoff = handler;
    l->owner = owner;
}

unsigned mp_tcp_next_worker(mp_tcp_listener *l, unsigned workers) {
    if (!workers) return 0;
    // Stagger the first connection across active leases. Later connections
    // on each port rotate independently, even when two ports accept in lockstep.
    if (!l->assigned_worker) {
        l->next_worker = l->relay->next_first_worker;
        l->relay->next_first_worker = (l->next_worker + 1) % workers;
        l->assigned_worker = true;
    }
    unsigned selected = l->next_worker;
    l->next_worker = (selected + 1) % workers;
    return selected;
}

mp_tcp_listener *mp_tcp_listen(mp_tcp_relay *r, uint16_t host, uint16_t guest,
                               uint16_t *selected, int profile) {
    mp_tcp_listener *l = new_listener(r, guest, profile);
    if (!l) return NULL;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    l->watch.fd = fd;
    struct sockaddr_in local = { .sin_len = sizeof(local), .sin_family = AF_INET,
        .sin_port = htons(host), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t size = sizeof(local);
    int one = 1;
    if (fd < 0 || prepare(fd) < 0 || setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0 ||
        bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0 || listen(fd, SOMAXCONN) < 0 ||
        getsockname(fd, (struct sockaddr *)&local, &size) < 0 ||
        watch_fd(r, &l->watch, EVFILT_READ, EV_ADD) < 0) {
        int err = errno;
        if (fd >= 0) close(fd);
        free(l);
        errno = err;
        return NULL;
    }
    *selected = ntohs(local.sin_port);
    return l;
}

// A second event for this pair may already be in the current batch.
static void close_pair(mp_tcp_relay *relay, struct pair *p) {
    if (p->retry_pending) change_watch(relay->kq, &p->retry, EVFILT_TIMER, EV_DELETE);
    close(p->client.watch.fd);
    if (p->guest.watch.fd >= 0) close(p->guest.watch.fd);
    if (p->listener->parent && p->listener->profile)
        atomic_fetch_sub_explicit(&p->listener->parent->group_active, 1, memory_order_relaxed);
    p->listener = NULL;
    p->next = relay->retired;
    relay->retired = p;
}

static unsigned socket_port(int fd, bool peer) {
    struct sockaddr_in a = {0};
    socklen_t len = sizeof(a);
    int rc = peer ? getpeername(fd, (struct sockaddr *)&a, &len) : getsockname(fd, (struct sockaddr *)&a, &len);
    return rc == 0 && a.sin_family == AF_INET ? ntohs(a.sin_port) : 0;
}

// SO_ERROR consumes the pending socket error. Read it only on a terminal
// path, after the final read or write and after capturing its errno.
static int socket_error(const struct endpoint *e) {
    int error = 0;
    socklen_t len = sizeof(error);
    return e->watch.fd >= 0 && getsockopt(e->watch.fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 ? error : 0;
}

static int event_error(const struct endpoint *e) {
    if (e->close_flags & EV_ERROR) return (int)e->close_data;
    return (e->close_flags & EV_EOF) ? (int)e->close_fflags : 0;
}

static void observe_close(struct pair *p, const char *reason, int error, bool setup) {
    mp_tcp_listener *l = p->listener;
    if (!l->profile || (p->early_close_seen && !error)) return;
    bool idle_fin = p->connected_at && !p->first_request_write_at && p->guest.eof;
    if (!error && !setup && !idle_fin && (!p->connected_at || !p->first_request_write_at)) return;
    bool first = !p->early_close_seen;
    p->early_close_seen = true;
    uint64_t count = 0;
    if (setup) count = ++l->stats.setup_closes;
    else if (idle_fin && first) count = ++l->stats.idle_guest_closes;
    else if (first && !p->guest_replied && p->first_request_write_at) count = ++l->stats.closes_before_response;
    if (error && !setup) ++l->stats.stream_errors;
    if (!error && count > 8) return;
    struct tcp_connection_info tcp = {0};
    socklen_t size = sizeof(tcp);
    int measured = p->guest.watch.fd >= 0 &&
        getsockopt(p->guest.watch.fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &tcp, &size) == 0;
    fprintf(stderr, "published TCP close reason=%s errno=%d epoch_us=%llu age_us=%llu "
            "client_port=%u published_port=%u guest_source_port=%u guest_port=%u "
            "client_flags=%u client_fflags=%u client_data=%lld client_so_error=%d "
            "guest_flags=%u guest_fflags=%u guest_data=%lld guest_so_error=%d "
            "client_fin=%d guest_fin=%d guest_replied=%d pending_request=%zu pending_reply=%zu "
            "tcp_info=%d guest_state=%u sent=%llu received=%llu retransmitted=%llu\n",
            reason, error, clock_gettime_nsec_np(CLOCK_REALTIME) / 1000,
            (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - p->accepted_at) / 1000,
            (unsigned)p->client_port, socket_port(p->client.watch.fd, false),
            socket_port(p->guest.watch.fd, false), ntohs(l->target.sin_port),
            p->client.close_flags, p->client.close_fflags, (long long)p->client.close_data, error ? socket_error(&p->client) : -1,
            p->guest.close_flags, p->guest.close_fflags, (long long)p->guest.close_data, error ? socket_error(&p->guest) : -1,
            p->client.eof, p->guest.eof, p->guest_replied, p->guest.length, p->client.length,
            measured, tcp.tcpi_state, tcp.tcpi_txbytes, tcp.tcpi_rxbytes, tcp.tcpi_txretransmitbytes);
}

static void retire(struct pair *p) {
    mp_tcp_listener *l = p->listener;
    observe_close(p, "relay_close", 0, false);
    if (p->prev) p->prev->next = p->next;
    else l->head = p->next;
    if (p->next) p->next->prev = p->prev;
    --l->active;
    close_pair(l->relay, p);
}

static void stream_failed(struct pair *p, struct endpoint *where, const char *reason, int error) {
    observe_close(p, reason, error, false);
    // A backend reset before its first byte must reach a waiting client as a
    // reset. A graceful FIN can still carry a reply in the other direction.
    if (where == &p->guest && !p->guest_replied && error == ECONNRESET) {
        const struct linger abortive = { .l_onoff = 1, .l_linger = 0 };
        if (setsockopt(p->client.watch.fd, SOL_SOCKET, SO_LINGER, &abortive, sizeof(abortive)) == 0 &&
            p->listener->profile) ++p->listener->stats.resets_forwarded;
    }
    retire(p);
}

static void reap(mp_tcp_relay *r) {
    while (r->retired) {
        struct pair *p = r->retired;
        r->retired = p->next;
        free(p->client.pending);
        free(p->guest.pending);
        free(p);
    }
}

void mp_tcp_release(mp_tcp_listener *l, mp_tcp_stats *stats) {
    // Timer registrations use an identifier, not a descriptor, and survive close(2).
    if (l->retry_accept) watch_fd(l->relay, &l->watch, EVFILT_TIMER, EV_DELETE);
    if (l->watch.fd >= 0) close(l->watch.fd);
    while (l->head) {
        struct pair *p = l->head;
        l->head = p->next;
        observe_close(p, "lease_release", 0, false);
        close_pair(l->relay, p);
    }
    reap(l->relay);
    // The accept owner joins each target's queue in sequence at revocation.
    // All target updates have completed before the parent is released.
    if (l->parent) {
        mp_tcp_stats *sum = &l->parent->stats, *one = &l->stats;
        sum->accepted += one->accepted;
        sum->connected += one->connected;
        sum->connect_errors += one->connect_errors;
        sum->idle_guest_closes += one->idle_guest_closes;
        sum->stream_errors += one->stream_errors;
        sum->resets_forwarded += one->resets_forwarded;
        sum->setup_closes += one->setup_closes;
        sum->closes_before_response += one->closes_before_response;
        sum->connect_retries += one->connect_retries;
        sum->recovered += one->recovered;
        sum->upload_bytes += one->upload_bytes;
        sum->download_bytes += one->download_bytes;
        sum->reads += one->reads;
        sum->writes += one->writes;
        sum->blocked_writes += one->blocked_writes;
        sum->bulk_directions += one->bulk_directions;
        sum->route_waits += one->route_waits;
        sum->handshake_timeouts += one->handshake_timeouts;
        if (l->last_error_at > l->parent->last_error_at) {
            l->parent->last_error_at = l->last_error_at;
            sum->last_connect_error = one->last_connect_error;
        }
        for (unsigned i = 0; i < 12; ++i) {
            sum->connect_us[i] += one->connect_us[i];
            sum->first_byte_us[i] += one->first_byte_us[i];
            sum->first_request_write_us[i] += one->first_request_write_us[i];
            sum->request_to_first_guest_byte_us[i] += one->request_to_first_guest_byte_us[i];
        }
    } else if (l->handoff) {
        l->stats.peak_active = atomic_load_explicit(&l->group_peak, memory_order_relaxed);
    }
    if (stats) *stats = l->stats;
    free(l);
}

void mp_tcp_relay_destroy(mp_tcp_relay *r) {
    close(r->kq);
    if (r->bulk.fd >= 0) close(r->bulk.fd);
    free(r);
}

static void observe(uint64_t bins[12], uint64_t ns) {
    unsigned i = 0;
    while (i < 11 && ns > (16000ULL << i)) ++i;
    ++bins[i];
}

static void connected(struct pair *p) {
    if (p->retried) ++p->listener->stats.recovered;
    if (!p->listener->profile) return;
    p->connected_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    ++p->listener->stats.connected;
    observe(p->listener->stats.connect_us, p->connected_at - p->accepted_at);
}

// The client read filter stays disabled throughout setup. No application byte
// can be consumed, sent or replayed while a guest handshake is pending.
static int dial_guest(struct pair *p, int timeout_seconds) {
    mp_tcp_listener *l = p->listener;
    mp_tcp_relay *r = l->relay;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    p->guest.watch.fd = fd;
    p->guest.close_flags = 0;
    p->guest.close_fflags = 0;
    p->guest.close_data = 0;
    if (fd < 0 || prepare(fd) < 0 || scope_guest(r, fd) < 0 ||
        (r->guest_receive_buffer && setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &r->guest_receive_buffer,
                                               sizeof(r->guest_receive_buffer)) < 0) ||
        setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &timeout_seconds, sizeof(timeout_seconds)) < 0) return -1;
    int rc = connect(fd, (struct sockaddr *)&l->target, sizeof(l->target));
    if (rc < 0 && errno != EINPROGRESS && errno != EINTR) return -1;
    p->guest.connecting = rc < 0;
    if (watch_fd(r, &p->guest.watch, EVFILT_READ, EV_ADD | (rc < 0 ? EV_DISABLE : EV_ENABLE)) < 0) return -1;
    if (rc < 0) return watch_fd(r, &p->guest.watch, EVFILT_WRITE, EV_ADD);
    if (watch_fd(r, &p->client.watch, EVFILT_READ, EV_ENABLE) < 0) return -1;
    connected(p);
    return 0;
}

static bool retry_guest(struct pair *p, int error) {
    switch (error) {
        case ETIMEDOUT: case EHOSTUNREACH: case ENETUNREACH: case EADDRNOTAVAIL:
        case ENETDOWN: case ENXIO: break;
        default: return false;
    }
    if (!p->retried) {
        mp_tcp_listener *owner = p->listener->parent ? p->listener->parent : p->listener;
        atomic_store_explicit(&owner->relay->path_failure, true, memory_order_relaxed);
    }
    if (error == ETIMEDOUT) ++p->listener->stats.handshake_timeouts;
    else ++p->listener->stats.route_waits;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now >= p->deadline) return false;
    if (p->guest.watch.fd >= 0) close(p->guest.watch.fd);
    p->guest.watch.fd = -1;
    p->guest.connecting = true;
    p->listener->relay->ifindex = 0;
    struct kevent timer;
    EV_SET(&timer, p->retry.fd, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, 125, &p->retry);
    if (kevent(p->listener->relay->kq, &timer, 1, NULL, 0, NULL) < 0) return false;
    p->retry_pending = p->retried = true;
    ++p->listener->stats.connect_retries;
    return true;
}

static void failed_handshake(struct pair *p, int error) {
    observe_close(p, "guest_connect", error, true);
    p->listener->last_error_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    p->listener->stats.last_connect_error = (unsigned)error;
    ++p->listener->stats.connect_errors;
    retire(p);
}

static void attempt_guest(struct pair *p) {
    int error = ETIMEDOUT;
    if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < p->deadline) {
        if (dial_guest(p, 1) == 0) return;
        error = errno;
        if (retry_guest(p, error)) return;
    }
    failed_handshake(p, error);
}

void mp_tcp_adopt(mp_tcp_listener *l, int client, uint64_t accepted_at) {
    if (l->profile) ++l->stats.accepted;
    struct pair *p = calloc(1, sizeof(*p));
    if (!p || prepare(client) < 0) {
        ++l->stats.connect_errors;
        free(p);
        close(client);
        return;
    }
    p->listener = l;
    p->accepted_at = accepted_at;
    // getpeername can fail after the peer has disconnected.
    if (l->profile) p->client_port = (uint16_t)socket_port(client, true);
    p->deadline = accepted_at + 10000000000ULL;
    p->retry = (struct watch){ RETRY_GUEST, client };
    p->client = (struct endpoint){ .watch = { STREAM, client }, .pair = p };
    p->guest = (struct endpoint){ .watch = { STREAM, -1 }, .pair = p };
    p->next = l->head;
    if (p->next) p->next->prev = p;
    l->head = p;
    ++l->active;
    if (l->profile && l->parent) {
        unsigned active = atomic_fetch_add_explicit(&l->parent->group_active, 1, memory_order_relaxed) + 1;
        unsigned peak = atomic_load_explicit(&l->parent->group_peak, memory_order_relaxed);
        while (peak < active && !atomic_compare_exchange_weak_explicit(&l->parent->group_peak, &peak, active,
               memory_order_relaxed, memory_order_relaxed)) {}
    } else if (l->profile && l->active > l->stats.peak_active) l->stats.peak_active = l->active;
    if (watch_fd(l->relay, &p->client.watch, EVFILT_READ, EV_ADD | EV_DISABLE) < 0) {
        ++l->stats.connect_errors;
        retire(p);
        return;
    }
    attempt_guest(p);
}

// Read directly into the worker scratch and immediately write to the peer.
// On backpressure, keep just the unwritten suffix and pause that reader.
static void pump(struct endpoint *src, struct endpoint *dst) {
    struct pair *p = src->pair;
    mp_tcp_listener *l = p->listener;
    mp_tcp_relay *r = l->relay;
    // One write per ready endpoint keeps sustained downloads from delaying
    // a new connect, FIN or small response for a full burst of copies.
    size_t count = dst->length;
    char *data = r->scratch;
    if (dst->pending) {
        data = dst->pending + dst->offset;
    } else {
        if (src->eof) return;
        ssize_t got = read(src->watch.fd, data, CHUNK);
        if (l->profile) ++l->stats.reads;
        if (got < 0) {
            if (errno != EAGAIN && errno != EINTR) {
                stream_failed(p, src, src == &p->guest ? "guest_read" : "client_read", errno);
            }
            return;
        }
        if (got == 0) {
            int error = event_error(src);
            if (error) {
                stream_failed(p, src, src == &p->guest ? "guest_read" : "client_read", error);
                return;
            }
            src->eof = true;
            if (src == &p->guest) observe_close(p, "guest_fin", 0, false);
            if (watch_fd(r, &src->watch, EVFILT_READ, EV_DISABLE) < 0) { retire(p); return; }
            // A disconnected write half may still have received bytes queued.
            if (shutdown(dst->watch.fd, SHUT_WR) < 0 && errno != ENOTCONN && errno != EPIPE) {
                stream_failed(p, dst, "shutdown_write", errno);
                return;
            }
            if (dst->eof) retire(p);
            return;
        }
        count = (size_t)got;
        if (src == &p->guest) {
            p->guest_replied = true;
            // One notification per data owner between watchdog polls. Counting only
            // bytes from the guest excludes accepts, writes and unanswered handshakes.
            if (!atomic_load_explicit(&r->guest_data, memory_order_relaxed))
                atomic_store_explicit(&r->guest_data, true, memory_order_relaxed);
        }
        if (!src->bulk_read && count >= LARGE_READ) {
            // Both queues have one serial owner. No bulk event can run until
            // this pump returns; closing the fd removes it from both queues.
            if (r->bulk.fd >= 0 && (change_watch(r->bulk.fd, &src->watch, EVFILT_READ, EV_ADD) < 0 ||
                change_watch(r->kq, &src->watch, EVFILT_READ, EV_DELETE) < 0)) { retire(p); return; }
            src->bulk_read = true;
            if (l->profile) ++l->stats.bulk_directions;
        }
        if (l->profile && src == &p->guest && p->connected_at) {
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            observe(l->stats.first_byte_us, now - p->connected_at);
            if (p->first_request_write_at)
                observe(l->stats.request_to_first_guest_byte_us, now - p->first_request_write_at);
            p->connected_at = 0;
        }
    }
    ssize_t sent = write(dst->watch.fd, data, count);
    if (l->profile) ++l->stats.writes;
    if (sent < 0) {
        if (errno != EAGAIN && errno != EINTR) {
            stream_failed(p, dst, dst == &p->guest ? "guest_write" : "client_write", errno);
            return;
        }
        sent = 0;
    }
    if (l->profile) {
        if (src == &p->client) l->stats.upload_bytes += (size_t)sent;
        else l->stats.download_bytes += (size_t)sent;
        if (sent > 0 && src == &p->client && p->connected_at && !p->first_request_write_at) {
            p->first_request_write_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            observe(l->stats.first_request_write_us, p->first_request_write_at - p->connected_at);
        }
    }
    if ((size_t)sent < count) {
        if (l->profile) ++l->stats.blocked_writes;
        size_t remaining = count - (size_t)sent;
        if (!dst->pending) {
            dst->pending = malloc(remaining);
            if (!dst->pending) { retire(p); return; }
            memcpy(dst->pending, r->scratch + sent, remaining);
            dst->length = remaining;
            struct kevent changes[] = { filter_change(&src->watch, EVFILT_READ, EV_DISABLE),
                                        filter_change(&dst->watch, EVFILT_WRITE, EV_ADD | EV_ENABLE) };
            if (update_stream_filters(r, changes, 2) < 0) retire(p);
        } else {
            dst->offset += (size_t)sent;
            dst->length = remaining;
        }
        return;
    }
    if (dst->pending) {
        free(dst->pending);
        dst->pending = NULL;
        dst->offset = dst->length = 0;
        struct kevent changes[] = { filter_change(&dst->watch, EVFILT_WRITE, EV_DISABLE),
                                    filter_change(&src->watch, EVFILT_READ, EV_ENABLE) };
        if (update_stream_filters(r, changes, 2) < 0) retire(p);
    }
}

static void finish_connect(struct pair *p) {
    int error = 0;
    socklen_t length = sizeof(error);
    mp_tcp_relay *r = p->listener->relay;
    if (getsockopt(p->guest.watch.fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) error = errno;
    if (!error) error = event_error(&p->guest);
    if (error) {
        if (retry_guest(p, error)) return;
        failed_handshake(p, error);
        return;
    }
    p->guest.connecting = false;
    struct kevent changes[] = { filter_change(&p->guest.watch, EVFILT_WRITE, EV_DISABLE),
                                filter_change(&p->guest.watch, EVFILT_READ, EV_ENABLE),
                                filter_change(&p->client.watch, EVFILT_READ, EV_ENABLE) };
    if (update_stream_filters(r, changes, 3) < 0) { retire(p); return; }
    connected(p);
    // The Mac client can already have sent its first request during connect.
    pump(&p->client, &p->guest);
}

// A full descriptor table leaves the listener readable. Suspend it briefly so
// existing streams and other leases can drain and free descriptors.
static void accept_ready(mp_tcp_listener *l, int16_t filter) {
    if (filter == EVFILT_TIMER) {
        l->retry_accept = false;
        watch_fd(l->relay, &l->watch, EVFILT_READ, EV_ENABLE);
        return;
    }
    for (int j = 0; j < 32; ++j) {
        int fd = accept(l->watch.fd, NULL, NULL);
        if (fd >= 0) {
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (l->handoff) l->handoff(l->owner, fd, now);
            else mp_tcp_adopt(l, fd, now);
            continue;
        }
        if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) {
            struct kevent timer;
            EV_SET(&timer, l->watch.fd, EVFILT_TIMER, EV_ADD | EV_ONESHOT, 0, 100, &l->watch);
            if (kevent(l->relay->kq, &timer, 1, NULL, 0, NULL) == 0) {
                l->retry_accept = true;
                watch_fd(l->relay, &l->watch, EVFILT_READ, EV_DISABLE);
            }
        }
        break;
    }
}

static void service_event(const struct kevent *event) {
    struct watch *w = event->udata;
    if (w->kind == ACCEPT) {
        accept_ready((mp_tcp_listener *)w, event->filter);
        return;
    }
    if (w->kind == RETRY_GUEST) {
        struct pair *p = (struct pair *)((char *)w - offsetof(struct pair, retry));
        if (p->listener && p->retry_pending) {
            p->retry_pending = false;
            attempt_guest(p);
        }
        return;
    }
    struct endpoint *e = (struct endpoint *)w;
    struct pair *p = e->pair;
    // A second event from the returned batch can outlive its connection.
    // Retired endpoints retain their storage until the whole drain finishes.
    if (!p->listener || p->retry_pending || event->ident != (uintptr_t)e->watch.fd) return;
    if (event->flags & (EV_EOF | EV_ERROR)) {
        e->close_flags = event->flags;
        e->close_fflags = event->fflags;
        e->close_data = event->data;
    }
    struct endpoint *peer = opposite(e);
    if (p->guest.connecting) {
        if (e == &p->guest && event->filter == EVFILT_WRITE) finish_connect(p);
    } else if (event->filter == EVFILT_WRITE) {
        if (e->length) pump(peer, e);
    } else if (!e->eof && !peer->length) {
        pump(e, peer);
    }
}

// A dedicated data owner already has a separate accept queue. Read each
// ready set once, service handshakes and small flows first, then service every
// bulk event returned by the kernel. Bound the callback to allow revocation.
static void drain_data(mp_tcp_relay *r, int budget) {
    struct kevent events[DATA_READY_BATCH];
    const struct timespec now = {0};
    int serviced = 0;
    while (serviced < budget) {
        int limit = budget - serviced;
        int n = kevent(r->kq, NULL, 0, events, limit < DATA_READY_BATCH ? limit : DATA_READY_BATCH, &now);
        if (n <= 0) break;
        bool bulk[DATA_READY_BATCH] = {0};
        for (int i = 0; i < n; ++i) {
            struct watch *w = events[i].udata;
            if (w->kind == STREAM) {
                struct endpoint *e = (struct endpoint *)w;
                bulk[i] = (events[i].filter == EVFILT_READ ? e : opposite(e))->bulk_read;
            }
            if (!bulk[i]) service_event(&events[i]);
        }
        for (int i = 0; i < n; ++i) if (bulk[i]) service_event(&events[i]);
        serviced += n;
    }
}

int mp_tcp_data_callback_events(int data_workers) {
#if defined(MICROPOD_BENCH_FIXED_RELAY_BUDGET) && MICROPOD_BENCH_FIXED_RELAY_BUDGET
    // Benchmark both worker counts with one binary and the two-worker callback limit.
    (void)data_workers;
    return EVENTS_PER_TURN;
#else
    return data_workers > 2 ? DATA_READY_BATCH : EVENTS_PER_TURN;
#endif
}

void mp_tcp_relay_drain(mp_tcp_relay *r, int data_workers) {
    if (r->bulk.fd < 0) {
        // Handoffs and revocations share this dispatch queue with the drain.
        // Wider groups can copy concurrently, so yield each owner sooner.
        drain_data(r, mp_tcp_data_callback_events(data_workers));
        reap(r);
        return;
    }
    // The dedicated accept queue stays responsive during larger data batches.
    const int batch = data_workers ? THROUGHPUT_BULK_BATCH : INTERACTIVE_BULK_BATCH;
    struct kevent events[EVENTS_PER_TURN];
    struct timespec now = {0};
    // Recheck new and interactive sockets between groups of bulk reads. A
    // bounded callback also leaves the serial owner free for lease revocation.
    int serviced = 0;
    while (serviced < EVENTS_PER_TURN) {
        int n = kevent(r->kq, NULL, 0, events, EVENTS_PER_TURN, &now);
        if (n <= 0) break;
        bool bulk_ready = false;
        for (int i = 0; i < n; ++i) {
            if (events[i].udata == &r->bulk) { bulk_ready = true; continue; }
            service_event(&events[i]);
            ++serviced;
        }
        if (!bulk_ready) break;
        n = kevent(r->bulk.fd, NULL, 0, events, batch, &now);
        if (n <= 0) break;
        for (int i = 0; i < n; ++i) service_event(&events[i]);
        serviced += n;
    }
    reap(r);
}
