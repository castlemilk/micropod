// Fixture shims around the pinned IPv4 lookup and unicast RX path.
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t __be32;
typedef int rx_handler_result_t;
enum { IPVL_IPV4 = 4, IPVL_ARP = 9, RX_HANDLER_PASS = 0 };
struct iphdr { __be32 saddr, daddr; };
struct arphdr { char pad[8]; };
struct ipvl_addr { struct ipvl_addr *next; int atype; struct in_addr ip4addr; int owner; };
struct net_device { int addr_len; };
struct ipvl_port { struct net_device *dev; struct ipvl_addr *hlhead[1]; };
struct sk_buff { struct iphdr header; int owner; };
#define IS_ENABLED(x) 0
#define get_unaligned(p) (*(p))
#define hlist_for_each_entry_rcu(v,head,member) for ((v)=*(head); (v); (v)=(v)->next)
static u8 ipvlan_get_v4_hash(__be32 address) { (void)address; return 0; }
static void *ipvlan_get_L3_hdr(struct ipvl_port *port, struct sk_buff *skb, int *type) {
    (void)port; *type = IPVL_IPV4; return &skb->header;
}
static int ipvlan_rcv_frame(struct ipvl_addr *addr, struct sk_buff **pskb, bool local) {
    if (local) abort();
    (*pskb)->owner = addr->owner;
    return 1;
}
#include "ipvlan_functions.inc"

int choose_child(const unsigned char *dest, const unsigned char *one, const unsigned char *two) {
    struct ipvl_addr first = {.atype=IPVL_IPV4,.owner=1};
    struct ipvl_addr second = {.atype=IPVL_IPV4,.owner=2,.next=&first};
    memcpy(&first.ip4addr.s_addr, one, 4);
    memcpy(&second.ip4addr.s_addr, two, 4);
    struct ipvl_port port = {.hlhead={&second}};
    struct sk_buff packet = {0};
    memcpy(&packet.header.daddr, dest, 4);
    struct sk_buff *pskb = &packet;
    ipvlan_handle_mode_l3(&pskb, &port);
    return packet.owner;
}
