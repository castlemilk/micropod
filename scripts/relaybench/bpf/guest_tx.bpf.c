// SPDX-License-Identifier: GPL-2.0
// Diagnostic for the serialized virtio-net TX queue on the benchmark Linux guest.
#ifndef RELAYBENCH_NATIVE_FIXTURE
#include <linux/bpf.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#endif
#include "guest_tx.h"

// Only these fields are read. libbpf relocates their offsets and the TX queue
// array stride using the running kernel's BTF (CONFIG_NET_NS and CONFIG_BQL).
struct ns_common { unsigned int inum; };
struct net { struct ns_common ns; };
struct dql { unsigned int num_queued; };
struct netdev_queue { struct dql dql; };
struct net_device {
    int ifindex;
    struct { struct net *net; } nd_net;
    struct netdev_queue *_tx;
};
struct sk_buff {
    unsigned short queue_mapping;
    unsigned int len;
};

struct tx_call {
    __u64 skb_addr;
    __u64 dev_addr;
    __u64 queue_addr;
    __u64 end_ns;
    __u32 before;
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct tx_config);
} config SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct tx_counts);
} counts SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(map_flags, BPF_F_WRONLY);
    __type(key, __u32);
    __type(value, struct tx_call);
} pending SEC(".maps");

SEC("raw_tp/net_dev_start_xmit")
int tx_enter(struct bpf_raw_tracepoint_args *ctx)
{
    const __u64 now = bpf_ktime_get_ns();
    const __u32 key = 0;
    const struct tx_config *cfg = bpf_map_lookup_elem(&config, &key);
    if (!cfg || now < cfg->start_ns || now >= cfg->end_ns)
        return 0;

    struct tx_counts *total = bpf_map_lookup_elem(&counts, &key);
    if (!total)
        return 0;
    struct net_device *dev = (void *)ctx->args[1];
    int ifindex;
    if (bpf_core_read(&ifindex, sizeof(ifindex), &dev->ifindex))
        goto read_error;
    if ((__u32)ifindex != cfg->ifindex)
        return 0;

    struct net *net;
    __u32 inum;
    if (bpf_core_read(&net, sizeof(net), &dev->nd_net.net) ||
        bpf_core_read(&inum, sizeof(inum), &net->ns.inum))
        goto read_error;
    if (inum != cfg->netns_inum)
        return 0;

    struct sk_buff *skb = (void *)ctx->args[0];
    __u16 mapping;
    if (bpf_core_read(&mapping, sizeof(mapping), &skb->queue_mapping))
        goto read_error;
    if (mapping != cfg->queue)
        return 0;

    total->attempts++;
    __u32 len;
    if (bpf_core_read(&len, sizeof(len), &skb->len))
        goto read_error;
    total->attempted_bytes += len;

    struct tx_call *call = bpf_map_lookup_elem(&pending, &key);
    if (!call)
        goto read_error;
    if (call->skb_addr) {
        total->overlaps++;
        return 0;
    }
    struct netdev_queue *base;
    if (bpf_core_read(&base, sizeof(base), &dev->_tx))
        goto read_error;
    struct netdev_queue *txq = (void *)((__u64)base +
        (__u64)mapping * bpf_core_type_size(struct netdev_queue));
    __u32 before;
    if (bpf_core_read(&before, sizeof(before), &txq->dql.num_queued))
        goto read_error;

    call->dev_addr = ctx->args[1];
    call->queue_addr = (__u64)txq;
    call->before = before;
    call->end_ns = cfg->end_ns;
    call->skb_addr = ctx->args[0];
    return 0;

read_error:
    total->read_errors++;
    return 0;
}

SEC("raw_tp/net_dev_xmit")
int tx_exit(struct bpf_raw_tracepoint_args *ctx)
{
    const __u32 key = 0;
    struct tx_call *call = bpf_map_lookup_elem(&pending, &key);
    // The driver may have freed the skb. Compare only its saved pointer value.
    if (!call || !call->skb_addr || call->skb_addr != ctx->args[0] ||
        call->dev_addr != ctx->args[2])
        return 0;

    call->skb_addr = 0;
    struct tx_counts *total = bpf_map_lookup_elem(&counts, &key);
    if (!total)
        return 0;
    const struct tx_config *cfg = bpf_map_lookup_elem(&config, &key);
    const __u64 now = bpf_ktime_get_ns();
    // The loader can shorten the watchdog deadline at the end of the workload.
    if (!cfg || now >= cfg->end_ns || now >= call->end_ns) {
        total->boundary_crossings++;
        return 0;
    }

    total->completed_calls++;
    switch ((int)ctx->args[1]) {
    case 0: total->tx_ok++; break;
    case 0x10: total->tx_busy++; break;
    default: total->tx_other++; break;
    }

    struct netdev_queue *txq = (void *)call->queue_addr;
    __u32 after;
    if (bpf_core_read(&after, sizeof(after), &txq->dql.num_queued)) {
        total->read_errors++;
        return 0;
    }
    // Linux DQL advances this u32 under the TX queue's enqueue serialization.
    // Reclaim updates num_completed independently; it cannot cancel this delta.
    total->dql_charged_bytes += (__u32)(after - call->before);
    return 0;
}

#include "service_send.bpf.h"

char LICENSE[] SEC("license") = "GPL";
