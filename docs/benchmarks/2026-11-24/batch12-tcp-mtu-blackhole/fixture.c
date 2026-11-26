#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t u32;
typedef int32_t s32;
struct tcphdr { unsigned char bytes[20]; };
struct net {
    struct { int sysctl_tcp_base_mss, sysctl_tcp_min_snd_mss, sysctl_tcp_mtu_probe_floor;
             int sysctl_tcp_mtu_probing, sysctl_tcp_retries1; } ipv4;
};
struct af_ops { int net_header_len; };
struct inet_connection_sock {
    struct af_ops *icsk_af_ops;
    struct { int enabled, search_high, search_low, probe_size, probe_timestamp; } icsk_mtup;
    int icsk_ext_hdr_len, icsk_pmtu_cookie, icsk_retransmits;
};
struct tcp_sock {
    int tcp_header_len, max_window, mss_cache, tcp_usec_ts;
    unsigned int retrans_stamp, tcp_mstamp;
    struct { int mss_clamp; } rx_opt;
};
struct sock { struct net net; struct tcp_sock tp; struct inet_connection_sock icsk; int sk_state; };

#define HZ 250
#define TCP_MSS_DEFAULT 536
#define TCPF_SYN_SENT (1U << 2)
#define TCPF_SYN_RECV (1U << 3)
#define USEC_PER_MSEC 1000
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
#define max_t(t,a,b) max((t)(a),(t)(b))
#define tcp_sk(s) (&(s)->tp)
#define inet_csk(s) (&(s)->icsk)
#define sock_net(s) (&(s)->net)
#define READ_ONCE(v) (v)
#define likely(v) (v)
#define ilog2(v) (31U - (unsigned)__builtin_clz(v))
#define jiffies_to_msecs(j) ((j) * (1000 / HZ))
#define jiffies_to_usecs(j) ((j) * (1000000 / HZ))
#define tcp_rto_max(sk) TCP_RTO_MAX
#define tcp_timeout_init(sk) HZ
#define tcp_time_stamp_ts(tp) (time_ms)
#define __dst_negative_advice(sk) ((void)(sk))
static unsigned int time_ms, tcp_jiffies32;

#include "kernel_excerpt.h"

int main(int argc, char **argv)
{
    if (argc != 2) return 1;
    struct af_ops af = { .net_header_len = 20 };
    struct sock sk = { .sk_state = 1, .icsk.icsk_af_ops = &af,
                       .tp.tcp_header_len = 32, .tp.max_window = 262144,
                       .tp.rx_opt.mss_clamp = 8960, .tp.retrans_stamp = 1000 };
    defaults(&sk.net);
    sk.net.ipv4.sysctl_tcp_mtu_probing = atoi(argv[1]);
    tcp_mtup_init(&sk);
    tcp_sync_mss(&sk, 9000);
    const unsigned int checks[] = {0, 2996, 3000};
    for (unsigned int i = 0; i < sizeof(checks)/sizeof(checks[0]); i++) {
        time_ms = sk.tp.retrans_stamp + checks[i];
        tcp_jiffies32 = time_ms / (1000 / HZ);
        sk.icsk.icsk_retransmits = i != 0;
        established_timeout_check(&sk);
        printf("%u %d %d %d\n", checks[i], sk.tp.mss_cache, sk.icsk.icsk_mtup.enabled,
               sk.icsk.icsk_mtup.search_low);
    }
    return 0;
}
