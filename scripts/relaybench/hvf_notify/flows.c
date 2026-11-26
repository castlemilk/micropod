// Transfer real guest pages into separate, already-connected TCP sockets.
// Each writable flow gets one bounded send per pass. Its pages stay private
// until Darwin has accepted every byte or the connection has failed.
#include "vm.h"
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>

enum { MAX_FLOWS = 32, FRAME = 65536, BATCH = 8, SLOT = FRAME * BATCH };
struct flow {
    uint64_t cookie;
    size_t done, pending, offset;
    int error;
    unsigned sends, waits, short_writes, would_block, interrupted;
};
static struct flow flows[MAX_FLOWS];
static struct pollfd sockets[MAX_FLOWS];
static unsigned count, frames, group_limit, guest_mode;

struct grant {
    uint64_t slot, previous, cookie, frames, written;
};
struct grant_table {
    _Atomic uint64_t count, completed;
    struct grant items[MAX_FLOWS];
};
_Static_assert(sizeof(struct grant) == 40 && offsetof(struct grant, written) == 32 &&
               offsetof(struct grant_table, items) == 16 && sizeof(struct grant_table) <= MP_PAGE,
               "EL1 descriptor layout");

struct counters {
    unsigned grants, data_exits, max_group, polls;
};

static bool submit_table(struct probe_vm *vm, const unsigned *owners, unsigned length,
                         unsigned char *staged, struct counters *work) {
    struct grant_table *table = vm->data;
    atomic_store_explicit(&table->completed, 0, memory_order_relaxed);
    atomic_store_explicit(&table->count, length, memory_order_release);
    if (!hv_checked(hv_vcpu_run(vm->cpu), "submit grant table") || probe_notification(vm, true) != (length ? 0 : 1))
        return false;
    if (!length)
        return true;
    if (atomic_load_explicit(&table->completed, memory_order_acquire) != length)
        return false;
    // Only the completion sequence comes from the guest. Derive host offsets
    // and lengths from the socket's still-owned state, validating the descriptor.
    for (unsigned j = 0; j < length; ++j) {
        struct grant *g = &table->items[j];
        unsigned slot = owners[j];
        if (g->slot != slot)
            return false;
        struct flow *f = &flows[slot];
        size_t previous = f->done / FRAME;
        size_t grant = frames - previous < BATCH ? frames - previous : BATCH;
        if (sockets[slot].fd < 0 || f->pending || g->previous != previous || g->cookie != f->cookie ||
            g->frames != grant || g->written != previous + grant)
            return false;
        f->offset = 0;
        f->pending = grant * FRAME;
        size_t off = (size_t)slot * SLOT;
        if (staged)
            memcpy(staged + off, (unsigned char *)vm->data + MP_PAGE + off, f->pending);
    }
    work->grants += length;
    ++work->data_exits;
    if (length > work->max_group)
        work->max_group = length;
    return true;
}

static bool refill_writable(struct probe_vm *vm, unsigned char *staged, struct counters *work) {
    struct grant_table *table = vm->data;
    unsigned length = 0;
    unsigned owners[MAX_FLOWS];
    for (unsigned i = 0; i < count; ++i) {
        struct flow *f = &flows[i];
        if (sockets[i].fd < 0 || !sockets[i].revents || f->pending)
            continue;
        size_t previous = f->done / FRAME;
        size_t grant = frames - previous < BATCH ? frames - previous : BATCH;
        owners[length] = i;
        table->items[length++] = (struct grant){i, previous, f->cookie, grant, UINT64_MAX};
        if (length == group_limit) {
            if (!submit_table(vm, owners, length, staged, work))
                return false;
            length = 0;
        }
    }
    return !length || submit_table(vm, owners, length, staged, work);
}

static bool generate(struct probe_vm *vm, unsigned slot, size_t previous, size_t grant) {
    _Atomic uint64_t *header = vm->data;
    atomic_store_explicit(&header[1], slot, memory_order_relaxed);
    atomic_store_explicit(&header[2], flows[slot].cookie, memory_order_relaxed);
    atomic_store_explicit(&header[3], grant, memory_order_relaxed);
    atomic_store_explicit(&header[0], previous, memory_order_release);
    if (!hv_checked(hv_vcpu_run(vm->cpu), "produce frames"))
        return false;
    if (!grant)
        return probe_notification(vm, true) == 1;
    return probe_notification(vm, true) == 0 &&
           atomic_load_explicit(&header[4], memory_order_acquire) == previous + grant;
}

static bool window(struct probe_vm *vm, unsigned block, unsigned direct, unsigned batch) {
    if (block != 1 || batch != BATCH || !hv_checked(mp_tx_boot(vm->cpu, vm->code_ipa, vm->data_ipa,
            vm->bell_ipa, frames, guest_mode), "flow guest setup"))
        return false;
    unsigned char *mapped = (unsigned char *)vm->data + MP_PAGE;
    unsigned char *staged = direct ? NULL : malloc(count * SLOT);
    if (!direct && !staged)
        return false;
    memset(mapped, 0, count * SLOT);
    if (staged)
        memset(staged, 0, count * SLOT);
    unsigned active = count;
    struct counters work = {0};
    uint64_t guest0, guest1;
    if (!hv_checked(hv_vcpu_get_exec_time(vm->cpu, &guest0), "guest time before transfer")) {
        free(staged);
        return false;
    }
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    uint64_t start = mach_absolute_time();
    bool ok = true;
    while (active && ok && probe_ns(mach_absolute_time() - start) < 35000000000ULL) {
        ++work.polls;
        int ready = poll(sockets, count, 200);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready < 0) {
            perror("poll");
            ok = false;
            break;
        }
        if (group_limit && !refill_writable(vm, staged, &work)) {
            ok = false;
            break;
        }
        for (unsigned i = 0; i < count; ++i) {
            struct flow *f = &flows[i];
            if (sockets[i].fd < 0)
                continue;
            if (!sockets[i].revents) {
                ++f->waits;
                continue;
            }
            unsigned char *slot = mapped + i * SLOT;
            if (f->pending == 0) {
                size_t previous = f->done / FRAME;
                size_t grant = frames - previous < BATCH ? frames - previous : BATCH;
                if (group_limit || !generate(vm, i, previous, grant)) {
                    ok = false;
                    break;
                }
                ++work.grants;
                ++work.data_exits;
                work.max_group = 1;
                f->pending = grant * FRAME;
                f->offset = 0;
                if (!direct)
                    memcpy(staged + i * SLOT, slot, f->pending);
            }
            if (!direct)
                slot = staged + i * SLOT;
            ++f->sends;
            ssize_t n = send(sockets[i].fd, slot + f->offset, f->pending, MSG_DONTWAIT);
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                ++f->would_block;
                continue;
            }
            if (n < 0 && errno == EINTR) {
                ++f->interrupted;
                continue;
            }
            if (n <= 0) {
                f->error = n < 0 ? errno : EPIPE;
            } else {
                if ((size_t)n < f->pending)
                    ++f->short_writes;
                f->offset += (size_t)n;
                f->pending -= (size_t)n;
                f->done += (size_t)n;
            }
            if (f->error || f->done == (size_t)frames * FRAME) {
                sockets[i].fd = -1;
                --active;
            }
        }
    }
    ok = ok && active == 0 && (group_limit ? submit_table(vm, NULL, 0, staged, &work) : generate(vm, 0, 0, 0));
    uint64_t wall = probe_ns(mach_absolute_time() - start);
    uint64_t used = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu;
    free(staged);
    if (!ok || !hv_checked(hv_vcpu_get_exec_time(vm->cpu, &guest1), "guest time after transfer") || guest1 < guest0) {
        fprintf(stderr, "multi-flow producer failed with %u unfinished flows\n", active);
        return false;
    }
    printf("{\"direct\":%u,\"grants\":%u,\"data_exits\":%u,\"max_group\":%u,\"group_limit\":%u,"
           "\"vector_store\":%u,\"completion_exits\":1,\"polls\":%u,\"vcpu_ns\":%llu,"
           "\"wall_ns\":%llu,\"sender_cpu_ns\":%llu,\"flows\":[",
           direct, work.grants, work.data_exits, work.max_group, group_limit, guest_mode == 2, work.polls,
           (unsigned long long)probe_ns(guest1 - guest0), (unsigned long long)wall, (unsigned long long)used);
    for (unsigned i = 0; i < count; ++i) {
        struct flow *f = &flows[i];
        printf("%s{\"bytes\":%zu,\"error\":%d,\"sends\":%u,\"waits\":%u,\"short_writes\":%u,"
               "\"would_block\":%u,\"interrupted\":%u}",
                i ? "," : "", f->done, f->error, f->sends, f->waits, f->short_writes, f->would_block, f->interrupted);
    }
    puts("]}");
    return true;
}

int main(int argc, char **argv) {
    if (argc >= 5 && strcmp(argv[1], "--group") == 0) {
        if (strcmp(argv[2], "1") == 0)
            group_limit = 1;
        else if (strcmp(argv[2], "8") == 0)
            group_limit = 8;
        else
            return 2;
        if (strcmp(argv[3], "scalar") == 0)
            guest_mode = 1;
        else if (strcmp(argv[3], "neon") == 0)
            guest_mode = 2;
        else
            return 2;
        argc -= 3;
        argv += 3;
    }
    if (argc < 3 || argc > MAX_FLOWS + 2 || sscanf(argv[1], "%u", &frames) != 1 || !frames || frames > 1024)
        return 2;
    count = (unsigned)argc - 2;
    for (unsigned i = 0; i < count; ++i) {
        unsigned long long cookie;
        int fd, one = 1;
        if (sscanf(argv[i + 2], "%d:%llu", &fd, &cookie) != 2 || fd < 3 || !cookie ||
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) != 0)
            return 2;
        flows[i].cookie = cookie;
        sockets[i] = (struct pollfd){.fd = fd, .events = POLLOUT};
    }
    return probe_run(MP_PAGE + count * SLOT, window);
}
