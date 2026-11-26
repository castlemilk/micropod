/* The observed answer is whether the 7.3.5 ring setter reaches a resize.
 * Stop at that boundary. No device or CPU timing is modeled. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t u32;
#define EINVAL 22
#define EOPNOTSUPP 95
struct virtqueue { u32 num_max, size; };
struct send_queue { struct virtqueue *vq; };
struct receive_queue { struct virtqueue *vq; int dim_lock; };
struct coalescing { u32 max_usecs, max_packets; };
struct virtnet_info {
    int max_queue_pairs;
    struct send_queue *sq;
    struct receive_queue *rq;
    struct coalescing intr_coal_tx, intr_coal_rx;
};
struct net_device { struct virtnet_info vi; };
struct ethtool_ringparam {
    u32 rx_pending, tx_pending, rx_max_pending, tx_max_pending;
    u32 rx_mini_pending, rx_jumbo_pending;
};
struct kernel_ethtool_ringparam;
struct netlink_ext_ack;
#define netdev_priv(dev) (&(dev)->vi)
#define virtqueue_get_vring_size(vq) ((vq)->size)
#define mutex_lock(lock) ((void)(lock))
#define mutex_unlock(lock) ((void)(lock))
static unsigned int tx_resize_calls, rx_resize_calls;
enum { reached_hardware = -12345 };

static int virtnet_tx_resize(struct virtnet_info *vi, struct send_queue *sq, u32 n)
{
    tx_resize_calls++;
    return reached_hardware;
}
static int virtnet_rx_resize(struct virtnet_info *vi, struct receive_queue *rq, u32 n)
{
    rx_resize_calls++;
    return reached_hardware;
}
#define virtnet_send_tx_ctrl_coal_vq_cmd(...) (abort(), 0)
#define virtnet_send_rx_ctrl_coal_vq_cmd(...) (abort(), 0)
#include "driver.inc"

int main(int argc, char **argv)
{
    if (argc != 6) return 2;
    struct virtqueue rx = {atoi(argv[1]), atoi(argv[2])};
    struct virtqueue tx = {atoi(argv[3]), atoi(argv[4])};
    struct send_queue sq = {&tx};
    struct receive_queue rq = {&rx, 0};
    struct net_device dev = {.vi = {.sq = &sq, .rq = &rq, .max_queue_pairs = 1}};
    struct ethtool_ringparam requested = {0}, after = {0};
    virtnet_get_ringparam(&dev, &requested, NULL, NULL);
    requested.tx_pending = atoi(argv[5]);
    int rc = virtnet_set_ringparam(&dev, &requested, NULL, NULL);
    virtnet_get_ringparam(&dev, &after, NULL, NULL);
    printf("%d %u %u %u %u\n", rc, tx_resize_calls, rx_resize_calls,
           after.rx_pending, after.tx_pending);
    return 0;
}
