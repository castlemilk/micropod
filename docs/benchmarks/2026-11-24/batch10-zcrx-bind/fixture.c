/* Readback and callback shims around five original Linux admission functions. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define ENOMEM 12
#define EINVAL 22
#define EOPNOTSUPP 95
#define EEXIST 17
#define EBUSY 16
#define EAGAIN 11
#define QCFG_RX_PAGE_SIZE 1
#define ETHTOOL_TCP_DATA_SPLIT_ENABLED 1
struct device { unsigned long *dma_mask; struct device *parent; };
struct net_device;
struct netdev_queue_config;
struct netdev_queue_mgmt_ops {
    unsigned int ndo_queue_mem_size;
    int (*ndo_queue_mem_alloc)(struct net_device *, struct netdev_queue_config *, void *, unsigned int);
    void (*ndo_queue_mem_free)(struct net_device *, void *);
    int (*ndo_queue_start)(struct net_device *, struct netdev_queue_config *, void *, unsigned int);
    int (*ndo_queue_stop)(struct net_device *, void *, unsigned int);
    struct device *(*ndo_queue_get_dma_dev)(void *, unsigned int);
    int (*ndo_queue_create)(void);
    unsigned int supported_params;
};
struct pp_memory_provider_params { const void *mp_ops; unsigned int rx_page_size; };
struct netdev_rx_queue { struct pp_memory_provider_params mp_params; };
struct netlink_ext_ack { const char *message; };
struct netdev_queue_config { int dummy; };
struct configuration { int hds_config, hds_thresh; };
struct net_device {
    struct device dev;
    const struct netdev_queue_mgmt_ops *queue_mgmt_ops;
    unsigned int real_num_rx_queues, real_num_tx_queues;
    bool present;
    struct configuration *cfg;
    struct netdev_rx_queue rxq;
};
static unsigned int reconfig_calls;
static unsigned int provider_seen;
#define NL_SET_ERR_MSG(e, s) ((e)->message = (s))
#define netif_device_present(d) ((d)->present)
#define dev_xdp_prog_count(d) 0
#define __netif_get_rx_queue(d, i) (&(d)->rxq)
#define netdev_queue_config(d,i,c) ((void)0)
#define netdev_queue_config_validate(d,i,c,e) 0
#define netdev_assert_locked(d) ((void)0)
#define kvzalloc(n, flags) calloc(1, (n))
#define kvfree(ptr) free(ptr)
#define page_pool_check_memory_provider(d,rxq) ((void)(rxq), 0)
#define netif_running(d) true
#define swap(a,b) do { void *tmp = (a); (a) = (b); (b) = tmp; } while (0)
#define WARN(...) ((void)0)
static int allocate(struct net_device *dev, struct netdev_queue_config *cfg, void *mem,
                    unsigned int idx) {
    (void)cfg; (void)mem; (void)idx;
    ++reconfig_calls;
    provider_seen = dev->rxq.mp_params.mp_ops != NULL;
    return -EAGAIN; /* Sentinel at the driver's first memory allocation callback. */
}
static void release_mem(struct net_device *d, void *mem) { (void)d; (void)mem; abort(); }
static int start(struct net_device *d, struct netdev_queue_config *cfg, void *mem, unsigned int i) {
    (void)d; (void)cfg; (void)mem; (void)i; abort();
}
static int stop(struct net_device *d, void *mem, unsigned int i) {
    (void)d; (void)mem; (void)i; abort();
}
#include "linux-admission.h"
static int create(void) { return 1; }

int main(void) {
    unsigned int mask, ops;
    while (scanf("%u%u", &mask, &ops) == 2) {
        unsigned long dma_bits = ~0UL;
        struct device parent = {.dma_mask = mask ? &dma_bits : NULL};
        struct netdev_queue_mgmt_ops peer_ops = {.ndo_queue_create = create};
        const struct netdev_queue_mgmt_ops provider_ops = {
            .ndo_queue_mem_size=1, .ndo_queue_mem_alloc=allocate, .ndo_queue_mem_free=release_mem,
            .ndo_queue_start=start, .ndo_queue_stop=stop
        };
        struct configuration cfg = {.hds_config = ETHTOOL_TCP_DATA_SPLIT_ENABLED};
        struct net_device peer = {.queue_mgmt_ops = &peer_ops, .real_num_rx_queues = 1,
                                  .real_num_tx_queues = 1};
        struct net_device lower = {.dev.parent = &parent, .present = true, .cfg = &cfg,
                                   .real_num_rx_queues = 1, .real_num_tx_queues = 1,
                                   .queue_mgmt_ops = ops ? &provider_ops : NULL};
        struct netlink_ext_ack ack = {0};
        const struct pp_memory_provider_params p = {.mp_ops = &cfg};
        bool create_ok = netdev_can_create_queue(&peer, &ack);
        bool lease_ok = netdev_can_lease_queue(&lower, &ack);
        bool dma = __netdev_queue_get_dma_dev(&lower, 0) != NULL;
        reconfig_calls = provider_seen = 0;
        int ret = dma ? __netif_mp_open_rxq(&lower, 0, &p, &ack) : -EOPNOTSUPP;
        printf("%u %u %u %d %u %u %u\n", create_ok, lease_ok, dma, ret,
               reconfig_calls, provider_seen, lower.rxq.mp_params.mp_ops != NULL);
    }
    return ferror(stdin) != 0;
}
