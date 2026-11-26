/* Short-lived in-process mock for one virtio controller and two RX/TX queue pairs. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint16_t u16;
typedef uint32_t u32;
#define EINVAL 22
#define EBUSY 16
#define ENOMEM 12
#define EOPNOTSUPP 95
#define VIRTIO_NET_F_VQ_NOTF_COAL 52
#define VIRTIO_NET_F_NOTF_COAL 53
#define VIRTIO_NET_CTRL_NOTF_COAL 1
#define VIRTIO_NET_CTRL_NOTF_COAL_VQ_SET 2
#define VIRTIO_NET_CTRL_NOTF_COAL_RX_SET 3
#define VIRTIO_NET_CTRL_NOTF_COAL_TX_SET 4
#define IFF_UP 1
#define NAPI_POLL_WEIGHT 64
#define cpu_to_le16(v) (v)
#define cpu_to_le32(v) (v)
#define kzalloc_obj(v) calloc(1, sizeof(v))
static void free_at_exit(void *ptr) { void *v; memcpy(&v, ptr, sizeof(v)); free(v); }
#define __free(fn) __attribute__((cleanup(free_at_exit)))
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
struct coal { u32 max_usecs, max_packets; };
struct virtio_net_ctrl_coal_vq { u16 vqn; struct coal coal; };
struct virtio_net_ctrl_coal_tx { u32 tx_usecs, tx_max_packets; };
struct virtio_net_ctrl_coal_rx { u32 rx_usecs, rx_max_packets; };
struct scatterlist { void *payload; };
#define sg_init_one(s, d, len) ((s)->payload = (d))
struct kernel_ethtool_coalesce { int dummy; };
struct netlink_ext_ack { int dummy; };
struct ethtool_coalesce {
    u32 tx_coalesce_usecs, rx_coalesce_usecs, tx_max_coalesced_frames, rx_max_coalesced_frames;
    bool use_adaptive_rx_coalesce;
};
struct queue {
    struct coal intr_coal;
    int dim_lock;
    bool dim_enabled;
    struct { int weight; } napi;
    void *xsk_pool;
};
struct virtnet_info {
    uint64_t vdev;
    u16 max_queue_pairs;
    struct queue rq[2], sq[2];
    struct coal intr_coal_rx, intr_coal_tx;
    bool rx_dim_enabled;
};
struct net_device { struct virtnet_info *vi; int flags; };
#define netdev_priv(d) ((d)->vi)
#define virtio_has_feature(v, f) (((v) >> (f)) & 1ULL)
static int refuse_tx;
static char trace[3];
static unsigned int sent;
static bool virtnet_send_command(struct virtnet_info *vi, unsigned int class, unsigned int cmd,
                                 const struct scatterlist *sg) {
    (void)vi;
    if (class != VIRTIO_NET_CTRL_NOTF_COAL || sent >= 2) abort();
    bool tx;
    switch (cmd) {
    case VIRTIO_NET_CTRL_NOTF_COAL_VQ_SET: {
        const struct virtio_net_ctrl_coal_vq *vq = sg->payload;
        if (vq->vqn > 1) abort();
        tx = vq->vqn == 1;
        trace[sent++] = tx ? 't' : 'r'; break;
    }
    case VIRTIO_NET_CTRL_NOTF_COAL_RX_SET: tx = false; trace[sent++] = 'R'; break;
    case VIRTIO_NET_CTRL_NOTF_COAL_TX_SET: tx = true; trace[sent++] = 'T'; break;
    default: abort();
    }
    return !(tx && refuse_tx);
}
#include "driver.h"

int main(void) {
    unsigned int global_feature, queue_feature, hetero, perqueue;
    while (scanf("%u%u%u%d%u", &global_feature, &queue_feature, &hetero, &refuse_tx, &perqueue) == 5) {
        struct virtnet_info vi = {.max_queue_pairs=2};
        struct net_device dev = {.flags=IFF_UP, .vi=&vi};
        vi.vdev = ((uint64_t)global_feature << VIRTIO_NET_F_NOTF_COAL) |
                  ((uint64_t)queue_feature << VIRTIO_NET_F_VQ_NOTF_COAL);
        vi.intr_coal_tx = (struct coal){8, 1};
        vi.intr_coal_rx = (struct coal){10, 1};
        if (!global_feature && !queue_feature) {
            vi.intr_coal_tx.max_usecs = vi.intr_coal_rx.max_usecs = 0;
        }
        for (unsigned int i = 0; i < 2; ++i) {
            vi.sq[i].intr_coal = vi.intr_coal_tx;
            vi.rq[i].intr_coal = vi.intr_coal_rx;
            vi.sq[i].napi.weight = NAPI_POLL_WEIGHT;
        }
        if (hetero) { vi.rq[1].intr_coal.max_usecs = 80; vi.sq[1].intr_coal.max_usecs = 16; }
        struct ethtool_coalesce request = {.rx_coalesce_usecs=20, .tx_coalesce_usecs=vi.intr_coal_tx.max_usecs,
                                            .rx_max_coalesced_frames=1, .tx_max_coalesced_frames=1};
        sent = 0; memset(trace, 0, sizeof(trace));
        int rc = perqueue ? virtnet_set_per_queue_coalesce(&dev, 0, &request) :
                            virtnet_set_coalesce(&dev, &request, NULL, NULL);
        printf("%d %s %u %u %u %u %u %u\n", rc, sent ? trace : "-",
               vi.rq[0].intr_coal.max_usecs, vi.rq[1].intr_coal.max_usecs,
               vi.sq[0].intr_coal.max_usecs, vi.sq[1].intr_coal.max_usecs,
               vi.intr_coal_rx.max_usecs, vi.intr_coal_tx.max_usecs);
    }
    return ferror(stdin) != 0;
}
