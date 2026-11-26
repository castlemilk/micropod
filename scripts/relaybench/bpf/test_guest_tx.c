// SPDX-License-Identifier: GPL-2.0
// Compile on the host: cc -std=c11 -Wall -Wextra -Werror test_guest_tx.c -o test_guest_tx
// This exercises the actual observer functions with in-memory helper substitutes.
#include <assert.h>
#include <stdint.h>
#include <string.h>

typedef uint16_t __u16;
typedef uint32_t __u32;
typedef uint64_t __u64;
struct bpf_raw_tracepoint_args { __u64 args[4]; };

#define RELAYBENCH_NATIVE_FIXTURE
#define SEC(name)
#define __uint(name, value) int name
#define __type(name, value) value *name
#define bpf_core_type_size(type) sizeof(type)
#define bpf_core_read(dest, size, src) fixture_read(dest, size, src)
static __u64 clock_ns;
static __u64 bpf_ktime_get_ns(void) { return clock_ns; }
static __u64 bpf_get_current_pid_tgid(void) { return (__u64)77 << 32; }
static void *bpf_map_lookup_elem(const void *, const __u32 *);
static const void *failed_read;
static int fixture_read(void *dest, size_t size, const void *src)
{
    if (src == failed_read)
        return -1;
    memcpy(dest, src, size);
    return 0;
}

#include "guest_tx.bpf.c"

static struct tx_config selected;
static struct tx_counts counters;
static struct tx_call active;
static struct service_totals service;
static void *bpf_map_lookup_elem(const void *map, const __u32 *key)
{
    assert(*key == 0);
    if (map == &config) return &selected;
    if (map == &counts) return &counters;
    if (map == &pending) return &active;
    if (map == &service_counts) return &service;
    assert(0);
    return NULL;
}

static struct net ns = { .ns.inum = 64 };
static struct netdev_queue queues[2];
static struct net_device nic = { .ifindex = 7, .nd_net.net = &ns, ._tx = queues };
static struct sk_buff skb = { .queue_mapping = 1, .len = 16384 };

static void enter(struct sk_buff *packet)
{
    struct bpf_raw_tracepoint_args entry = { .args = { (uintptr_t)packet, (uintptr_t)&nic } };
    tx_enter(&entry);
}

static void finish(uintptr_t packet, int rc)
{
    struct bpf_raw_tracepoint_args exit = { .args = { packet, (__u64)rc, (uintptr_t)&nic, skb.len } };
    tx_exit(&exit);
}

static void reset(void)
{
    selected = (struct tx_config){ .start_ns = 100, .end_ns = 200,
        .netns_inum = ns.ns.inum, .ifindex = nic.ifindex, .queue = 1 };
    memset(&counters, 0, sizeof(counters));
    memset(&active, 0, sizeof(active));
    memset(queues, 0, sizeof(queues));
    failed_read = NULL;
    clock_ns = 100;
}

int main(void)
{
    reset();
    selected.netns_inum++;
    enter(&skb);
    selected.netns_inum--;
    selected.ifindex++;
    enter(&skb);
    selected.ifindex--;
    selected.queue = 0;
    enter(&skb);
    selected.queue = 1;
    clock_ns = 99;
    enter(&skb);
    clock_ns = 200;
    enter(&skb);
    assert(counters.attempts == 0 && counters.read_errors == 0);

    reset();
    queues[1].dql.num_queued = UINT32_MAX - 500;
    enter(&skb);
    queues[0].dql.num_queued += 1000000;
    queues[1].dql.num_queued += 1000;
    finish(1, 0); // A nested unrelated return, even with an invalid skb address.
    assert(counters.completed_calls == 0);
    finish((uintptr_t)&skb, 0);
    assert(counters.tx_ok == 1 && counters.dql_charged_bytes == 1000);
    enter(&skb);
    finish((uintptr_t)&skb, 0x10);
    enter(&skb);
    finish((uintptr_t)&skb, -1);
    assert(counters.attempts == 3 && counters.attempted_bytes == 3 * skb.len);
    assert(counters.completed_calls == 3 && counters.tx_busy == 1 && counters.tx_other == 1);
    assert(counters.dql_charged_bytes == 1000 && !active.skb_addr);

    reset();
    enter(&skb);
    selected.end_ns = 125;
    clock_ns = 125;
    queues[1].dql.num_queued += 800;
    finish((uintptr_t)&skb, 0);
    assert(counters.boundary_crossings == 1 && !counters.completed_calls);
    assert(!active.skb_addr && counters.dql_charged_bytes == 0);

    reset();
    struct sk_buff nested = skb;
    enter(&skb);
    enter(&nested);
    finish((uintptr_t)&nested, 0);
    finish((uintptr_t)&skb, 0);
    assert(counters.attempts == 2 && counters.completed_calls == 1 && counters.overlaps == 1);

    reset();
    failed_read = &queues[1].dql.num_queued;
    enter(&skb);
    finish((uintptr_t)&skb, 0);
    assert(counters.attempts == 1 && !counters.completed_calls && counters.read_errors == 1);
    failed_read = NULL;
    enter(&skb);
    failed_read = &queues[1].dql.num_queued;
    finish((uintptr_t)&skb, 0);
    assert(counters.completed_calls == 1 && counters.read_errors == 2 && !active.skb_addr);
    assert(counters.dql_charged_bytes == 0);

    reset();
    selected.service_tgid = 77;
    selected.service_port = 8000;
    selected.service_netns = ns.ns.inum;
    struct sock sock = { .__sk_common = { .skc_num = 8000, .skc_net.net = &ns } };
    __u64 ctx[] = { (uintptr_t)&sock, 0, 256, 100 };
    clock_ns = selected.start_ns - 1;
    service_send(ctx);
    clock_ns = selected.end_ns;
    service_send(ctx);
    clock_ns = selected.start_ns;
    failed_read = &sock.__sk_common.skc_num;
    service_send(ctx);
    failed_read = NULL;
    assert(service.read_errors == 1 && !service.calls);
    selected.service_tgid++;
    service_send(ctx);
    selected.service_tgid--;
    selected.service_port++;
    service_send(ctx);
    selected.service_port--;
    selected.service_netns++;
    service_send(ctx);
    selected.service_netns--;
    assert(!service.calls);
    service_send(ctx);
    ctx[3] = (__u64)-11;
    service_send(ctx);
    ctx[3] = 256;
    service_send(ctx);
    ctx[3] = 0;
    service_send(ctx);
    ctx[3] = 257;
    service_send(ctx);
    assert(service.calls == 5 && service.requested_bytes == 1280);
    assert(service.accepted_bytes == 356 && service.full_calls == 1 && service.short_calls == 1);
    assert(service.error_calls == 1 && service.zero_calls == 1 && service.oversized_returns == 1);
    return 0;
}
