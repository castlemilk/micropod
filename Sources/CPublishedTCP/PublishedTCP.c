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
#define LARGE_READ (16 * 1024)

enum event_kind { ACCEPT, STREAM, BULK_READY, RETRY_GUEST };
struct watch { enum event_kind kind; int fd; };
struct pair;

struct mp_tcp_relay {
    int kq;
    struct watch bulk;
    struct in_addr guest, gateway;
    unsigned ifindex;
    atomic_bool path_failure;
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
    uint64_t last_error_at;
    bool profile, retry_accept;
    mp_tcp_stats stats;
};

struct endpoint {
    struct watch watch;
    struct pair *pair;
    bool connecting, eof, bulk_read;
    char *pending;
    size_t offset, length;
};

struct pair {
    mp_tcp_listener *listener;
    struct pair *prev, *next;
    struct endpoint client, guest;
    struct watch retry;
    bool retry_pending, retried;
    uint64_t deadline;
    uint64_t accepted_at, connected_at, first_request_write_at;
};

static int change_watch(int kq, struct watch *w, int16_t filter, uint16_t flags) {
    struct kevent change;
    EV_SET(&change, w->fd, filter, flags, 0, 0, w);
    int status;
    do { status = kevent(kq, &change, 1, NULL, 0, NULL); } while (status < 0 && errno == EINTR);
    return status;
}

static struct endpoint *opposite(struct endpoint *e) {
    return e == &e->pair->client ? &e->pair->guest : &e->pair->client;
}

static int watch_fd(mp_tcp_relay *r, struct watch *w, int16_t filter, uint16_t flags) {
    int q = r->kq;
    if (w->kind == STREAM) {
        struct endpoint *e = (struct endpoint *)w;
        // READ consumes this direction; WRITE flushes its peer's pending bytes.
        if ((filter == EVFILT_READ ? e : opposite(e))->bulk_read) q = r->bulk.fd;
    }
    return change_watch(q, w, filter, flags);
}

static int prepare(int fd) {
    int one = 1;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(fd, F_SETFL, O_NONBLOCK) < 0 ||
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ||
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) < 0) return -1;
    return 0;
}

mp_tcp_relay *mp_tcp_relay_create(const char *guest) {
    struct in_addr address;
    if (inet_pton(AF_INET, guest, &address) != 1) { errno = EINVAL; return NULL; }
    mp_tcp_relay *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->guest = address;
    atomic_init(&r->path_failure, false);
    r->kq = kqueue();
    r->bulk = (struct watch){ BULK_READY, kqueue() };
    if (r->kq < 0 || r->bulk.fd < 0 || fcntl(r->kq, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(r->bulk.fd, F_SETFD, FD_CLOEXEC) < 0 || watch_fd(r, &r->bulk, EVFILT_READ, EV_ADD) < 0) {
        int err = errno;
        if (r->kq >= 0) close(r->kq);
        if (r->bulk.fd >= 0) close(r->bulk.fd);
        free(r);
        errno = err;
        return NULL;
    }
    return r;
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

static void retire(struct pair *p) {
    mp_tcp_listener *l = p->listener;
    if (p->prev) p->prev->next = p->next;
    else l->head = p->next;
    if (p->next) p->next->prev = p->prev;
    --l->active;
    close_pair(l->relay, p);
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
    close(r->bulk.fd);
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
    if (fd < 0 || prepare(fd) < 0 || scope_guest(r, fd) < 0 ||
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
            if (errno != EAGAIN && errno != EINTR) retire(p);
            return;
        }
        if (got == 0) {
            src->eof = true;
            if (watch_fd(r, &src->watch, EVFILT_READ, EV_DISABLE) < 0 ||
                shutdown(dst->watch.fd, SHUT_WR) < 0 || dst->eof) retire(p);
            return;
        }
        count = (size_t)got;
        if (!src->bulk_read && count >= LARGE_READ) {
            // Both queues have one serial owner. No bulk event can run until
            // this pump returns; closing the fd removes it from both queues.
            if (change_watch(r->bulk.fd, &src->watch, EVFILT_READ, EV_ADD) < 0 ||
                change_watch(r->kq, &src->watch, EVFILT_READ, EV_DELETE) < 0) { retire(p); return; }
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
        if (errno != EAGAIN && errno != EINTR) { retire(p); return; }
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
            if (watch_fd(r, &src->watch, EVFILT_READ, EV_DISABLE) < 0 ||
                watch_fd(r, &dst->watch, EVFILT_WRITE, EV_ADD | EV_ENABLE) < 0) retire(p);
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
        if (watch_fd(r, &dst->watch, EVFILT_WRITE, EV_DISABLE) < 0 ||
            watch_fd(r, &src->watch, EVFILT_READ, EV_ENABLE) < 0) { retire(p); return; }
    }
}

static void finish_connect(struct pair *p) {
    int error = 0;
    socklen_t length = sizeof(error);
    mp_tcp_relay *r = p->listener->relay;
    if (getsockopt(p->guest.watch.fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) error = errno;
    if (error) {
        if (retry_guest(p, error)) return;
        failed_handshake(p, error);
        return;
    }
    p->guest.connecting = false;
    if (watch_fd(r, &p->guest.watch, EVFILT_WRITE, EV_DISABLE) < 0 ||
        watch_fd(r, &p->guest.watch, EVFILT_READ, EV_ENABLE) < 0 ||
        watch_fd(r, &p->client.watch, EVFILT_READ, EV_ENABLE) < 0) { retire(p); return; }
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
    if (!p->listener) return;
    struct endpoint *peer = opposite(e);
    if (p->guest.connecting) {
        if (e == &p->guest && event->filter == EVFILT_WRITE) finish_connect(p);
    } else if (event->filter == EVFILT_WRITE) {
        if (e->length) pump(peer, e);
    } else if (!e->eof && !peer->length) {
        pump(e, peer);
    }
}

void mp_tcp_relay_drain(mp_tcp_relay *r, int dedicated_data_owner) {
    // The dedicated accept queue stays responsive during larger data batches.
    const int batch = dedicated_data_owner ? THROUGHPUT_BULK_BATCH : INTERACTIVE_BULK_BATCH;
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
