#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef uint32_t u32;
typedef uint32_t __u32;
typedef int32_t s32;

struct tcp_sock {
    u32 snd_cwnd, snd_ssthresh, snd_cwnd_stamp, snd_cwnd_used, packets_out;
    u32 lsndtime, snd_una, cwnd_usage_seq, max_packets_out, snd_nxt;
    bool is_cwnd_limited;
};
struct tcp_congestion_ops { bool cong_control; };
struct inet_connection_sock {
    s32 icsk_rto;
    int icsk_ca_state;
    const struct tcp_congestion_ops *icsk_ca_ops;
};
struct socket { unsigned long flags; };
struct network { struct { int sysctl_tcp_slow_start_after_idle; } ipv4; };
struct sock {
    struct tcp_sock tp;
    struct inet_connection_sock icsk;
    struct network net;
    struct socket *sk_socket;
    int sk_state, restart_events;
};
static u32 tcp_jiffies32;
enum {TCP_CA_Open, CA_EVENT_CWND_RESTART, TCP_CHRONO_SNDBUF_LIMITED};
enum {SOCK_NOSPACE = 0, TCPF_ESTABLISHED = 2, TCPF_CLOSE_WAIT = 256};
#define READ_ONCE(field) (field)
#define WRITE_ONCE(field,value) ((field)=(value))
#define tcp_sk(sk) (&(sk)->tp)
#define inet_csk(sk) (&(sk)->icsk)
#define sock_net(sk) (&(sk)->net)
#define tcp_snd_cwnd(tp) ((tp)->snd_cwnd)
#define tcp_snd_cwnd_set(tp,v) ((tp)->snd_cwnd=(v))
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define before(a,b) ((s32)((a)-(b))<0)
#define test_bit(bit,addr) (((*(addr))>>(bit))&1)
#define tcp_in_slow_start(tp) ((tp)->snd_cwnd < (tp)->snd_ssthresh)
#define tcp_in_cwnd_reduction(sk) (false)
#define tcp_init_cwnd(tp,dst) 10U
#define tcp_ca_event(sk,which) ((sk)->restart_events++)
#define tcp_write_queue_empty(sk) (true)
#define tcp_chrono_start(sk,which) ((void)0)
#include "policies.inc"

struct scenario {
    const char *name;
    bool validate, limited, buf_full, custom_control;
    u32 cwnd, packets_out, elapsed;
};
int main(void) {
    const struct scenario cases[] = {
        {"new_socket",false,false,false,false,10,0,0},
        {"continuous_inflight",false,false,false,false,64,32,450},
        {"return_exactly_one_rto",false,false,false,false,64,0,100},
        {"return_after_one_rto",false,false,false,false,64,0,101},
        {"return_after_two_rtos",false,false,false,false,64,0,201},
        {"return_after_five_rtos",false,false,false,false,64,0,501},
        {"already_at_initial_window",false,false,false,false,10,0,501},
        {"fully_cwnd_limited",true,true,false,false,64,64,101},
        {"steady_underfilled_window",true,false,false,false,64,8,100},
        {"underfilled_before_rto",true,false,false,false,64,8,99},
        {"send_buffer_exhausted",true,false,true,false,64,8,101},
        {"separate_cong_control",true,false,false,true,64,8,101},
    };
    for (size_t i=0; i<sizeof(cases)/sizeof(cases[0]); i++) {
        const struct scenario c = cases[i];
        for (unsigned arm=0; arm<2; arm++) {
            const unsigned policy = (i + arm + 1) % 2;
            struct tcp_congestion_ops ops = {.cong_control=c.custom_control};
            struct socket so = {.flags=c.buf_full};
            struct sock sk = {.icsk={.icsk_ca_ops=&ops,.icsk_rto=100,.icsk_ca_state=TCP_CA_Open},
                              .net={.ipv4={.sysctl_tcp_slow_start_after_idle=policy}},
                              .sk_socket=&so,.sk_state=1,
                              .tp={.snd_cwnd=c.cwnd,.snd_ssthresh=32,.packets_out=c.packets_out,
                                   .snd_una=100,.snd_nxt=1000,.cwnd_usage_seq=100}};
            tcp_jiffies32=c.elapsed;
            if (c.validate) tcp_cwnd_validate(&sk,c.limited);
            else tcp_slow_start_after_idle_check(&sk);
            printf("%s,%u,%u,%s,%u,%u,%u,%u,%d\n",c.name,arm+1,policy,
                   c.validate?"validate":"before_send",c.elapsed,c.packets_out,c.cwnd,
                   sk.tp.snd_cwnd,sk.restart_events);
        }
    }
    return 0;
}
