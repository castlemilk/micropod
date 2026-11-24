/* The pinned driver and redirect functions are included verbatim by the runner.
 * Devices, namespaces and destinations below are fixed fixture objects. */
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define ETH_HLEN 14
#define IFF_UP 1
#define NET_XMIT_SUCCESS 0
#define NET_XMIT_DROP 1
#define NET_RX_SUCCESS 0
#define BPF_F_EGRESS (1U << 1)
#define BPF_F_NEIGH (1U << 16)
#define BPF_F_PEER (1U << 17)
#define BPF_F_NEXTHOP (1U << 18)
typedef int netdev_tx_t;
typedef unsigned int u32;
struct net { int id; };
struct bpf_net_context { int placeholder; };
struct bpf_mprog_entry { int placeholder; };
struct net_device;
struct netkit {
    enum netkit_action {NETKIT_NEXT=-1, NETKIT_PASS=0, NETKIT_DROP=2, NETKIT_REDIRECT=7} policy;
    struct bpf_mprog_entry *active;
    struct net_device *peer;
};
struct net_device {
    struct net *ns;
    struct netkit nk;
    int flags, tx, rx, drops;
};
struct sk_buff { int len, delivered, freed; struct net_device *dev; };
struct bpf_redirect_info { unsigned int flags, tgt_index; int nh; };
static struct bpf_redirect_info redirect_state;
static struct net left_ns = {1}, right_ns = {2};
static struct net_device source = {.ns=&left_ns, .flags=IFF_UP};
static struct net_device paired = {.ns=&right_ns, .flags=IFF_UP};
static struct net_device target = {.ns=&right_ns, .flags=IFF_UP};
static struct net_device target_peer = {.ns=&left_ns, .flags=IFF_UP};
static int target_present = 1;

#define likely(x) (x)
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define rcu_dereference(x) (x)
#define rcu_read_lock() ((void)0)
#define rcu_read_unlock() ((void)0)
#define dev_net(d) ((d)->ns)
#define net_eq(a,b) ((a) == (b))
#define netkit_priv(d) (&(d)->nk)
#define pskb_may_pull(s,n) ((s)->len >= (n))
#define skb_orphan_frags(s,g) 0
#define netkit_prep_forward(s,n,b) ((void)0)
#define eth_skb_pkt_type(s,p) ((void)0)
#define eth_skb_pull_mac(s) abort()
#define skb_postpull_rcsum(s,h,n) abort()
#define __netif_rx(s) (abort(), 0)
#define dev_sw_netstats_tx_add(d,n,b) ((d)->tx += (b))
#define dev_sw_netstats_rx_add(d,b) ((d)->rx += (b))
#define dev_core_stats_tx_dropped_inc(d) ((d)->drops++)
#define kfree_skb(s) ((s)->freed++)
#define bpf_net_ctx_set(ptr) (ptr)
#define bpf_net_ctx_clear(ptr) ((void)(ptr))
#define bpf_net_ctx_get_ri() (&redirect_state)
#define skb_at_tc_ingress(s) false
#define skb_scrub_packet(s,x) ((void)0)
#define __bpf_redirect_neigh(s,d,n) (abort(), -1)
#define dev_get_by_index_rcu(n,i) (((n) == &right_ns && (i) == 17 && target_present) ? &target : NULL)
#define skb_get_peer_dev(d) ((d) == &target ? &target_peer : NULL)

static int __bpf_redirect(struct sk_buff *skb, struct net_device *dev, unsigned int flags) {
    if (dev != &target_peer || flags != 0) abort();
    skb->delivered++;
    return 0;
}

static enum netkit_action netkit_run(const struct bpf_mprog_entry *entry,
                                     struct sk_buff *skb, enum netkit_action policy) {
    (void)entry; (void)skb; (void)policy;
    /* Equivalent return/redirect info to bpf_redirect_peer(17, BPF_F_EGRESS). */
    redirect_state.tgt_index = 17;
    redirect_state.flags = BPF_F_PEER | BPF_F_EGRESS;
    return NETKIT_REDIRECT;
}

#include "kernel_functions.inc"

int main(void) {
    struct bpf_mprog_entry active = {0};
    source.nk.peer = &paired;
    source.nk.active = &active;
    for (int arm=0; arm<2; arm++) {
        target_present = arm == 0;
        source.tx = source.drops = 0;
        int successes=0, delivered=0, freed=0;
        for (int i=0; i<32; i++) {
            struct sk_buff frame = {.len=1514, .dev=&source};
            successes += netkit_xmit(&frame, &source) == NET_XMIT_SUCCESS;
            if (frame.delivered + frame.freed != 1) abort();
            delivered += frame.delivered;
            freed += frame.freed;
        }
        printf("%d %d %d %d %d %d\n", target_present, successes, source.tx, source.drops, delivered, freed);
    }
}
