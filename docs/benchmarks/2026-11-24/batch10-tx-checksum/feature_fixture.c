/* Compile the pinned feature functions with small object accessors for two skbs. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t u64;
#define fls64(x) ((x) ? 64 - __builtin_clzll(x) : 0)
#include "features.inc"
struct net_device { netdev_features_t features, gso_partial_features; void *private; };
struct macvlan_dev { struct net_device *lowerdev; netdev_features_t set_features; };
struct sk_buff { int gso_type, ip_summed; unsigned short gso_size; bool frag_list; };
#define netdev_priv(dev) ((dev)->private)
#define netdev_dbg(...) ((void)0)
#define netdev_warn(...) ((void)0)
#define BUILD_BUG_ON(x) _Static_assert(!(x), #x)
#define skb_shinfo(skb) (skb)
#define skb_has_frag_list(skb) ((skb)->frag_list)
#define skb_is_gso(skb) ((skb)->gso_size != 0)
#define unlikely(x) (x)
#define CHECKSUM_PARTIAL 3
#define CHECKSUM_UNNECESSARY 1
#include "kernel.inc"

static void report_device(const char *label, netdev_features_t features) {
    struct sk_buff packet = {.gso_size = 1448, .ip_summed = CHECKSUM_PARTIAL};
    packet.gso_type = SKB_GSO_TCPV4;
    bool segment_v4 = netif_needs_gso(&packet, features);
    packet.gso_type = SKB_GSO_TCPV6;
    bool segment_v6 = netif_needs_gso(&packet, features);
    printf("%s %016llx %d %d %d %d %d %d %d %d %d %d\n",
        label, (unsigned long long)features,
        !!(features & NETIF_F_HW_CSUM), !!(features & NETIF_F_IP_CSUM),
        !!(features & NETIF_F_IPV6_CSUM), !!(features & NETIF_F_TSO),
        !!(features & NETIF_F_TSO6), !!(features & NETIF_F_TSO_MANGLEID),
        !!(features & NETIF_F_GSO), !!(features & NETIF_F_SG),
        segment_v4, segment_v6);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    netdev_features_t wanted = ARCHIVED_FEATURES;
    if (strcmp(argv[1], "checksum-off") == 0) wanted &= ~NETIF_F_HW_CSUM;
    else assert(strcmp(argv[1], "stock") == 0);
    struct net_device parent = {0};
    parent.features = netdev_fix_features(&parent, wanted);
    if (strcmp(argv[1], "stock") == 0) assert(parent.features == ARCHIVED_FEATURES);
    struct macvlan_dev vlan = {.lowerdev = &parent, .set_features = MACVLAN_FEATURES};
    struct net_device upper = {.private = &vlan};
    /* Hold upper requested capabilities fixed. Only the parent's checksum bit changes. */
    netdev_features_t upper_wanted = MACVLAN_FEATURES | ALWAYS_ON_FEATURES;
    upper.features = netdev_fix_features(&upper, macvlan_fix_features(&upper, upper_wanted));
    report_device("eth1", parent.features);
    report_device("macvlan", upper.features);
}
