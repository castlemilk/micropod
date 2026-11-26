/* The fixture constructs a complete IPv4 header and exposes it as the SKB's L3 header. */
#include <arpa/inet.h>
typedef uint16_t u16, __be16, __sum16;
#define __force
#define __always_inline inline __attribute__((always_inline))
enum { INET_ECN_MASK=3, INET_ECN_CE=3, ETH_P_IP=0x0800, ETH_P_IPV6=0x86dd };
struct iphdr { u8 version_ihl,tos; u16 len,id,frag; u8 ttl,proto; u16 check; uint32_t src,dst; };
struct ipv6hdr { u8 bytes[40]; };
_Static_assert(sizeof(struct iphdr)==20, "IPv4 header");
#define cpu_to_be16(value) __builtin_bswap16(value)
#define skb_protocol(skb,ignore_vlan) cpu_to_be16(ETH_P_IP)
#define skb_network_header(skb) ((skb)->network)
#define skb_tail_pointer(skb) ((skb)->network+sizeof(struct iphdr))
#define ip_hdr(skb) ((struct iphdr*)((skb)->network))
#define IP6_ECN_set_ce(skb,ip) (abort(),0)
