/* Userspace adapters for the pinned Linux transmit functions. No sockets or devices. */
#include <arpa/inet.h>
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NET_XMIT_SUCCESS 0
#define NET_XMIT_DROP 1
#define MACVLAN_MODE_BRIDGE 4
#define ETH_P_IP 0x0800
#define ETH_P_IPV6 0x86dd
#define RTN_UNICAST 1
#define RTN_LOCAL 2
#define FLOWI_FLAG_ANYSRC 1
#define noinline_for_stack
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define pr_debug_ratelimited(...) ((void)0)
#define pr_warn_ratelimited(...) ((void)0)
#define IS_ERR(x) ((x) == NULL)

struct net { int ns; };
struct net_device { struct net *net; int ifindex; void *priv; };
struct ethhdr { unsigned char h_dest[6], h_source[6]; uint16_t protocol; };
struct iphdr { unsigned char version_ihl, tos; uint16_t len, id, frag; unsigned char ttl, proto; uint16_t checksum; uint32_t saddr, daddr; };
struct sk_buff {
    struct net_device *dev;
    struct ethhdr eth;
    struct iphdr ip;
    unsigned char remaining[64], cb[16];
    size_t payload_size, offset;
    unsigned int mark, mac_header;
    uint16_t protocol;
};
struct macvlan_port { int unused; };
struct macvlan_dev { struct macvlan_port *port; struct net_device *lowerdev; int mode; };
struct ipvl_port { bool private; };
struct ipvl_dev { struct ipvl_port *port; struct net_device *phy_dev; };
struct ipvl_addr { int unused; };
struct flowi4 { int flowi4_oif, flowi4_flags, flowi4_mark, flowi4_dscp; uint32_t saddr, daddr; };
struct rtable { int rt_type, dst; };
static struct { int lower, parent_lookup, parent_local_out, dropped, cross_ns, errors; } events;
static uint32_t gateway, published, pod_ip;
static struct net child_ns = {1}, parent_ns = {2};
static struct net_device child = {&child_ns, 7, NULL}, eth1 = {&parent_ns, 3, NULL};
static struct rtable parent_gateway_route = {RTN_UNICAST, 1};
#define netdev_priv(d) ((d)->priv)
#define dev_net(d) ((d)->net)
#define net_eq(a,b) ((a) == (b))
#define skb_eth_hdr(s) (&(s)->eth)
#define eth_hdr(s) (&(s)->eth)
#define ip_hdr(s) (&(s)->ip)
#define ip4h_dscp(h) ((h)->tos >> 2)
#define IPCB(s) (&(s)->cb)
#define skb_mac_header_was_set(s) ((s)->mac_header == 0)
#define skb_pull(s,n) ((s)->offset += (n))
#define skb_reset_network_header(s) assert((s)->offset == sizeof(struct ethhdr))
#define skb_scrub_packet(s,x) do { assert(x); events.cross_ns++; } while (0)
#define pskb_network_may_pull(s,n) ((s)->payload_size >= (n))
#define skb_dst_set(s,d) assert((d) == &parent_gateway_route.dst)
#define net_xmit_eval(x) (x)
#define DEV_STATS_INC(d,k) do { assert((d) == &eth1); events.errors++; } while (0)
#define kfree_skb(s) (events.dropped++)
#define is_multicast_ether_addr(a) ((a)[0] & 1)
#define netdev_get_sb_channel(d) 0
#define ipvlan_is_private(p) ((p)->private)
#define ipvlan_is_vepa(p) false
#define ipvlan_process_v6_outbound(s) (abort(), NET_XMIT_DROP)
#define ip_rt_put(rt) abort()
#define skb_reset_mac_header(s) abort()
#define macvlan_broadcast(...) abort()
#define macvlan_hash_lookup(port,mac) ((void)(port), abort(), (struct macvlan_dev *)NULL)
#define dev_forward_skb(...) abort()
#define consume_skb(s) abort()
#define ipvlan_rcv_frame(...) abort()

static void *ipvlan_get_L3_hdr(struct ipvl_port *port, struct sk_buff *skb, int *type) {
    (void)port;
    *type = ntohs(skb->protocol);
    return *type == ETH_P_IP ? (void *)&skb->ip : (void *)skb->remaining;
}
static struct ipvl_addr *ipvlan_addr_lookup(struct ipvl_port *p, void *header, int type, bool dest) {
    (void)p;
    assert(dest);
    /* Only the recorded gateway is addressed; neither child owns the gateway. */
    uint32_t destination;
    if (type == ETH_P_IP) destination = ((const struct iphdr *)header)->daddr;
    else { assert(type == 0x0806); memcpy(&destination, (char *)header + 24, 4); }
    assert(destination == gateway && destination != pod_ip);
    return NULL;
}
static int dev_queue_xmit_accel(struct sk_buff *skb, struct net_device *channel) {
    assert(skb->dev == &eth1 && channel == NULL && skb->offset == 0);
    events.lower++;
    return NET_XMIT_SUCCESS;
}
static struct rtable *ip_route_output_flow(struct net *net, struct flowi4 *flow, void *socket) {
    assert(net == &parent_ns && flow->flowi4_oif == eth1.ifindex && socket == NULL);
    assert(flow->saddr == published && flow->daddr == gateway && flow->flowi4_flags == FLOWI_FLAG_ANYSRC);
    events.parent_lookup++;
    return &parent_gateway_route;
}
static int ip_local_out(struct net *net, void *socket, struct sk_buff *skb) {
    assert(net == &parent_ns && socket == NULL && skb->dev == &eth1);
    events.parent_local_out++;
    return NET_XMIT_SUCCESS;
}
#include "pinned_tx.inc"

int main(int argc, char **argv) {
    assert(argc == 5);
    bool ipvlan = strcmp(argv[1], "ipvlan-l3") == 0;
    assert(ipvlan || strcmp(argv[1], "macvlan-private") == 0);
    assert(inet_pton(AF_INET, argv[2], &published) == 1);
    assert(inet_pton(AF_INET, argv[3], &gateway) == 1);
    assert(inet_pton(AF_INET, argv[4], &pod_ip) == 1);
    unsigned char frame[256];
    size_t n = fread(frame, 1, sizeof(frame), stdin);
    assert(sizeof(struct ethhdr) == 14 && sizeof(struct iphdr) == 20 && n >= 42 && n <= 78);
    struct sk_buff skb = {.dev = &child};
    memcpy(&skb.eth, frame, 14);
    skb.payload_size = n - 14;
    skb.protocol = skb.eth.protocol;
    memcpy(&skb.ip, frame + 14, 20);
    memcpy(skb.remaining, frame + 14, skb.payload_size);
    if (ntohs(skb.protocol) == ETH_P_IP) assert(skb.ip.proto == 6);
    struct macvlan_port mac_port = {0};
    struct macvlan_dev mac = {&mac_port, &eth1, 1}; /* MACVLAN_MODE_PRIVATE */
    struct ipvl_port ip_port = {true};
    struct ipvl_dev ip = {&ip_port, &eth1};
    child.priv = ipvlan ? (void *)&ip : (void *)&mac;
    int ret = ipvlan ? ipvlan_xmit_mode_l3(&skb, &child) : macvlan_queue_xmit(&skb, &child);
    printf("{\"driver_return\":%d,\"direct_lower_egress\":%d,\"parent_route_lookup\":%d,"
        "\"parent_local_out\":%d,\"dropped_by_driver\":%d,\"crossed_namespaces\":%d}\n",
        ret, events.lower, events.parent_lookup, events.parent_local_out, events.dropped, events.cross_ns);
}
