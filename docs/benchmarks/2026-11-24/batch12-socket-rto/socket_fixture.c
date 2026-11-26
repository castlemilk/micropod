// SPDX-License-Identifier: GPL-2.0-or-later
// Model one SACK-capable Reno socket. The upstream case code selects and arms its loss-probe timer.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t u32;
enum { HZ=250, USEC_PER_MSEC=1000, EINVAL=22, TCP_RTO_MIN_US=45, RTAX_RTO_MIN=13,
       TCP_CA_Open=0, TCP_CA_CWR=2, ICSK_TIME_LOSS_PROBE=5 };
struct dst_entry { bool locked; u32 floor_ticks; };
struct inet_connection_sock { u32 icsk_rto_min, icsk_rto, icsk_ca_state; };
struct tcp_sock { int fastopen_rsk; u32 srtt_us, packets_out; bool sack; };
struct net { struct {int sysctl_tcp_rto_min_us, sysctl_tcp_early_retrans;} ipv4; };
struct sock {
    struct dst_entry route;
    struct inet_connection_sock connection;
    struct tcp_sock tcp;
    struct net net;
    u32 pending_rto_us, loss_probe_ticks;
};
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,y) ((x)=(y))
#define sock_net(sk) (&(sk)->net)
#define inet_csk(sk) (&(sk)->connection)
#define tcp_sk(sk) (&(sk)->tcp)
#define __sk_dst_get(sk) (&(sk)->route)
#define dst_metric_locked(dst, key) ((dst)->locked)
#define dst_metric_rtt(dst, key) ((dst)->floor_ticks)
#define tcp_rto_delta_us(sk) ((sk)->pending_rto_us)
#define rcu_access_pointer(x) (x)
#define tcp_is_sack(tp) ((tp)->sack)
#define min_t(type,x,y) ((type)(x)<(type)(y)?(type)(x):(type)(y))
static u32 usecs_to_jiffies(u32 value) {return (value + 3999) / 4000;}
static u32 jiffies_to_usecs(u32 value) {return value * 4000;}
static void tcp_reset_xmit_timer(struct sock *sk,int which,u32 timeout,bool clamp) {
    assert(which == ICSK_TIME_LOSS_PROBE && clamp);
    sk->loss_probe_ticks = timeout;
}
#include "timers.inc"

int main(void)
{
    for (int locked=0; locked<=1; locked++) {
        for (int packets=1; packets<=2; packets++) {
            for (int changed=0; changed<=1; changed++) {
                struct sock sk = {0};
                sk.route=(struct dst_entry){locked!=0,usecs_to_jiffies(20000)};
                sk.tcp=(struct tcp_sock){.srtt_us=1000*8,.packets_out=(u32)packets,.sack=true};
                sk.net.ipv4.sysctl_tcp_early_retrans=3;
                sk.pending_rto_us=400000;
                configure_defaults(&sk);
                int status=changed ? set_option(&sk,8000) : 0;
                assert(status==0 && tcp_schedule_loss_probe(&sk,false));
                printf("%d %d %d %d %d %u %u\n",locked,packets,changed,status,get_option(&sk),
                       tcp_rto_min_us(&sk),jiffies_to_usecs(sk.loss_probe_ticks));
            }
        }
    }
}
