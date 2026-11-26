// The driver gets a sequence of successful submissions to an unconsumed ring.
// Ring admission is modeled; BQL accounting and stop logic are compiled from Linux.
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
struct dql { unsigned int num_queued,adj_limit,last_obj_cnt,stall_thrs; };
struct virtqueue { int num_free; };
struct napi { int weight; };
struct send_queue { struct napi napi; struct virtqueue *vq; struct {int stop,wake,kicks,syncp;} stats; };
struct virtnet_info { struct send_queue *sq; };
struct netdev_queue { struct dql dql; unsigned long state,trans_start; };
struct net_device { struct virtnet_info vi; struct netdev_queue queue; };
struct sk_buff {unsigned int len;};
typedef int netdev_tx_t;
enum {NETDEV_TX_OK=0, MAX_SKB_FRAGS=17, __QUEUE_STATE_STACK_XOFF=1};
#define CONFIG_BQL 1
#define WARN_ON_ONCE(v) (v)
#define READ_ONCE(v) (v)
#define WRITE_ONCE(v,n) ((v)=(n))
#define barrier() ((void)0)
#define dql_queue_stall(d) abort()
#define DQL_MAX_OBJECT (0xffffffffU/16)
#define likely(v) (v)
#define unlikely(v) (v)
#define jiffies 1
#define smp_mb__before_atomic() ((void)0)
#define smp_mb__after_atomic() ((void)0)
#define set_bit(bit,state) (*(state)|=(1UL<<(bit)))
#define clear_bit(bit,state) (*(state)&=~(1UL<<(bit)))
#define netdev_priv(dev) (&(dev)->vi)
#define skb_get_queue_mapping(skb) 0
#define netdev_get_tx_queue(dev,n) ((void)(n),&(dev)->queue)
#define netif_tx_stop_queue(txq) ((txq)->state |= 1UL)
#define netif_tx_queue_stopped(txq) ((txq)->state & 1UL)
#define netif_xmit_stopped(txq) ((txq)->state != 0)
#define netif_start_subqueue(dev,n) abort()
#define u64_stats_update_begin(s) ((void)(s))
#define u64_stats_update_end(s) ((void)(s))
#define u64_stats_inc(s) (++*(s))
#define virtqueue_enable_cb_delayed(v) true
#define virtqueue_napi_schedule(n,v) abort()
#define virtqueue_disable_cb(v) ((void)0)
#define virtqueue_kick_prepare(v) true
#define virtqueue_notify(v) true
#define free_old_xmit(sq,txq,napi) ((void)(sq),(void)(txq),(void)(napi))
#define netdev_xmit_more() false
#define skb_orphan_frags(skb,gfp) 0
#define DEV_STATS_INC(dev,n) abort()
#define dev_kfree_skb_any(skb) abort()
#define skb_tx_timestamp(skb) ((void)0)
#define dev_warn(...) abort()
#define net_ratelimit() false
#define skb_orphan(skb) ((void)0)
#define skb_dst_drop(skb) ((void)0)
#define nf_reset_ct(skb) ((void)0)
static unsigned int ring_bytes;
static int xmit_skb(struct send_queue *sq, struct sk_buff *skb, bool orphan) {
    (void)orphan;
    assert(sq->vq->num_free>0);
    sq->vq->num_free--;
    ring_bytes+=skb->len;
    return 0;
}
#include "linux_functions.inc"

static void run(unsigned int size, int weight) {
    struct virtqueue vq={.num_free=256};
    struct send_queue sq={.napi={.weight=weight},.vq=&vq};
    struct net_device dev={.vi={.sq=&sq},.queue={.dql={.adj_limit=512U*1024}}};
    int submitted=0;
    ring_bytes=0;
    while (submitted<32 && !netif_xmit_stopped(&dev.queue)) {
        struct sk_buff skb={.len=size};
        assert(start_xmit(&skb,&dev)==NETDEV_TX_OK);
        submitted++;
    }
    assert(submitted==256-vq.num_free && submitted*size==ring_bytes && !sq.stats.stop);
    printf("%u %d %d %u %u %u %d %d\n",size,weight,submitted,ring_bytes,
           dev.queue.dql.num_queued,dev.queue.dql.adj_limit,
           !!(dev.queue.state & (1UL<<__QUEUE_STATE_STACK_XOFF)),sq.stats.stop);
}
int main(void) {
    const unsigned int sizes[]={1460,16384,32768,64512};
    for (unsigned int i=0;i<sizeof(sizes)/sizeof(sizes[0]);i++) {
        run(sizes[i],0);
        run(sizes[i],64);
    }
    return 0;
}
