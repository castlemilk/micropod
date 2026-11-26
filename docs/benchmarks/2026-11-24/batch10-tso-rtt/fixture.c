/* Substitutes fixed socket readbacks for two original Linux TCP functions. */
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint32_t u32;
struct sock;
struct tcp_congestion_ops { u32 (*min_tso_segs)(struct sock *); };
struct inet_connection_sock { const struct tcp_congestion_ops *icsk_ca_ops; };
struct net { struct { unsigned int sysctl_tcp_tso_rtt_log, sysctl_tcp_min_tso_segs; } ipv4; };
struct sock {
    unsigned long sk_pacing_rate;
    unsigned int sk_pacing_shift;
    u32 sk_gso_max_size, sk_gso_max_segs, min_rtt_us;
    struct net net;
    struct inet_connection_sock icsk;
};
#define READ_ONCE(value) (value)
#define BITS_PER_TYPE(value) (sizeof(value) * CHAR_BIT)
#define min_t(type, a, b) ((type)(a) < (type)(b) ? (type)(a) : (type)(b))
#define max_t(type, a, b) ((type)(a) > (type)(b) ? (type)(a) : (type)(b))
#define sock_net(sk) (&(sk)->net)
#define tcp_sk(sk) (sk)
#define tcp_min_rtt(tp) ((tp)->min_rtt_us)
#define inet_csk(sk) (&(sk)->icsk)
#include "kernel-functions.h"

int main(void) {
    const struct tcp_congestion_ops ops = {0};
    struct sock sk = {.icsk.icsk_ca_ops = &ops};
    unsigned int mss;
    int fields;
    while ((fields = scanf("%lu%u%u%u%u%u%u%u", &sk.sk_pacing_rate,
            &sk.min_rtt_us, &sk.net.ipv4.sysctl_tcp_tso_rtt_log, &mss,
            &sk.sk_gso_max_size, &sk.sk_gso_max_segs, &sk.sk_pacing_shift,
            &sk.net.ipv4.sysctl_tcp_min_tso_segs)) == 8) {
        if (mss == 0 || sk.net.ipv4.sysctl_tcp_tso_rtt_log > 31)
            return EXIT_FAILURE;
        printf("%u\n", tcp_tso_segs(&sk, mss));
    }
    return fields == EOF && !ferror(stdin) ? EXIT_SUCCESS : EXIT_FAILURE;
}
