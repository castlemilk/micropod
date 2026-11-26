/* One serialized ONETXQUEUE FIFO, one descriptor per SKB and no device completions. */
#include "previous_fixture.inc"
#include "driver.inc"

typedef unsigned short u16;
#define TCQ_F_ONETXQUEUE 1
#define NET_XMIT_MASK 15
#define NETDEV_TX_BUSY 16
struct Qdisc {
    struct sk_buff *(*dequeue)(struct Qdisc *);
    struct net_device *dev;
    struct netdev_queue *dev_queue;
    int flags, head;
    struct sk_buff fifo[32];
};
#define qdisc_dev(q) ((q)->dev)
#define netdev_cap_txqueue(dev, q) ((void)(dev), (q))
#define skb_set_queue_mapping(skb, q) ((void)(skb), assert((q) == 0))
#define skb_mark_not_on_list(skb) ((skb)->next = NULL)

static struct sk_buff *dequeue(struct Qdisc *q)
{
    return q->head < 32 ? &q->fifo[q->head++] : NULL;
}

/* dev_hard_start_xmit supplies next!=NULL; stand in for the per-CPU more flag. */
static int xmit_one(struct sk_buff *skb, struct net_device *dev,
                    struct netdev_queue *txq, bool more)
{
    assert(txq == &dev->queue);
    current_more = more;
    return start_xmit(skb, dev);
}
#include "qdisc.inc"

static void trial(unsigned int size, bool chaining)
{
    struct virtqueue vq = {.num_free = 256};
    struct send_queue sq = {.napi = {.weight = 64}, .vq = &vq};
    struct net_device dev = {.vi = {.sq = &sq}, .queue = {.dql = {.adj_limit = 524288}}};
    struct Qdisc q = {.dequeue = dequeue, .dev = &dev, .dev_queue = &dev.queue, .flags = TCQ_F_ONETXQUEUE};
    for (int i = 0; i < 32; i++)
        q.fifo[i].len = size;
    ring_bytes = 0;
    current_more = false;
    while (q.head < 32 && !netif_xmit_stopped(&dev.queue)) {
        int before = q.head, kicks = sq.stats.kicks, budget = 64, packets = 1, rc = -1;
        struct sk_buff *first = q.dequeue(&q);
        assert(qdisc_cap_skb_tx_queue(&q, first) == 0);
        if (chaining && qdisc_may_bulk(&q))
            try_bulk_dequeue_skb(&q, first, &dev.queue, &packets, budget);
        assert(packets == q.head - before);
        struct sk_buff *unsent = dev_hard_start_xmit(first, &dev, &dev.queue, &rc);
        assert(!unsent && rc == NETDEV_TX_OK && !sq.stats.stop);
        assert(q.head == 256 - vq.num_free && ring_bytes == size * q.head);
        assert(ring_bytes == dev.queue.dql.num_queued);
        printf("%u %d %d %d %u %u %d %d\n", size, chaining, before, packets,
               ring_bytes, dev.queue.dql.num_queued, sq.stats.kicks - kicks, !!netif_xmit_stopped(&dev.queue));
    }
}
int main(void)
{
    const unsigned int sizes[] = {1460, 16384, 32768, 64512};
    for (unsigned int i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
        trial(sizes[i], false);
        trial(sizes[i], true);
    }
    return 0;
}
