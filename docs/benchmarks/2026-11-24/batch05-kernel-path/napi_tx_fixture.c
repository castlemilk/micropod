// SPDX-License-Identifier: GPL-2.0-or-later
// Narrow userspace structures for the unmodified Linux driver functions below.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t u32;
#define IFF_UP 1
#define NAPI_POLL_WEIGHT 64
#define EBUSY 16
#define EINVAL 22
#define EOPNOTSUPP 95
#define VIRTIO_NET_F_VQ_NOTF_COAL 52

struct ethtool_coalesce {
    unsigned rx_coalesce_usecs, tx_coalesce_usecs;
    unsigned rx_max_coalesced_frames, tx_max_coalesced_frames;
    bool use_adaptive_rx_coalesce;
};

struct coalescing { unsigned max_usecs, max_packets; };
struct receive_queue { int dim_lock; struct coalescing intr_coal; bool dim_enabled; };
struct send_queue { struct { int weight; } napi; struct coalescing intr_coal; };
struct virtnet_info {
    void *vdev;
    u32 max_queue_pairs;
    struct send_queue sq[1];
    struct receive_queue rq[1];
};
struct net_device { struct virtnet_info *priv; int flags; };

static struct virtnet_info *netdev_priv(struct net_device *d) { return d->priv; }
static bool virtio_has_feature(void *device, int bit) {
    if (device != NULL || bit != VIRTIO_NET_F_VQ_NOTF_COAL) abort();
    return false;
}

// Negotiated per-virtqueue coalescing is deliberately absent from this fixture.
// Reaching a hardware command or lock would invalidate the chosen feature path.
#define mutex_lock(lock) abort()
#define mutex_unlock(lock) abort()
#define virtnet_send_notf_coal_vq_cmds(vi, ec, queue) (abort(), -1)

#include "virtio-tx-coalesce.inc"

static void sample(bool up, int initial, unsigned requested) {
    struct virtnet_info vi = {.max_queue_pairs = 1};
    struct net_device dev = {.priv = &vi, .flags = up ? IFF_UP : 0};
    vi.sq[0].napi.weight = initial;
    struct ethtool_coalesce req = {.rx_max_coalesced_frames = 1, .tx_max_coalesced_frames = requested};
    struct ethtool_coalesce got = {0};
    int status = virtnet_set_per_queue_coalesce(&dev, 0, &req);
    if (virtnet_get_per_queue_coalesce(&dev, 0, &got) != 0 || got.rx_max_coalesced_frames != 1) abort();
    printf("%d %d %u %d %d %u\n", up, initial, requested, status,
           vi.sq[0].napi.weight, got.tx_max_coalesced_frames);
}

int main(void) {
    for (int up = 0; up <= 1; ++up) {
        for (int initial = 0; initial <= NAPI_POLL_WEIGHT; initial += NAPI_POLL_WEIGHT) {
            sample(up, initial, initial != 0);
            sample(up, initial, initial == 0);
        }
    }
}
