/* Exercise the stock TCP push decision at a single call with explicit state.
 * Record the boundary call only. No TCP transmission or time is simulated. */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

struct sk_buff { int len,truesize; bool collapsible; };
struct tcp_sock { int unused; };
struct net { struct {int sysctl_tcp_autocorking;} ipv4; unsigned int autocork_events; };
struct charge { int samples[2], reads; };
struct sock {
    struct net net;
    struct sk_buff tail;
    struct tcp_sock tcp;
    bool rtx_empty;
    unsigned int sk_tsq_flags, push_calls;
    struct charge sk_wmem_alloc;
};
enum { TSQ_THROTTLED=0, MSG_MORE=0x8000, TCP_NAGLE_CORK=2 };
#define READ_ONCE(v) (v)
#define sock_net(sk) (&(sk)->net)
#define tcp_rtx_queue_empty(sk) ((sk)->rtx_empty)
#define tcp_skb_can_collapse_to(skb) ((skb)->collapsible)
#define tcp_sk(sk) (&(sk)->tcp)
#define tcp_write_queue_tail(sk) (&(sk)->tail)
#define forced_push(tp) ((void)(tp),false)
#define tcp_mark_push(tp,skb) ((void)(tp),(void)(skb))
#define tcp_mark_urg(tp,flags) ((void)(tp),(void)(flags))
#define test_bit(bit,flags) (*(flags)&(1U<<(bit)))
#define set_bit(bit,flags) (*(flags)|=(1U<<(bit)))
#define NET_INC_STATS(net,id) (++(net)->autocork_events)
#define smp_mb__after_atomic() ((void)0)

static int refcount_read(struct charge *charge) {
    assert(charge->reads<2);
    return charge->samples[charge->reads++];
}
static void __tcp_push_pending_frames(struct sock *sk,int mss,int nonagle) {
    assert(mss==1460 && nonagle==1);
    sk->push_calls++;
}
#include "tcp_functions.inc"

struct state {
    const char *name;
    int bytes,goal;
    bool in_rtx;
    int extra_first,extra_second;
    bool already_throttled,collapsible;
};

static void run(const struct state *s,int policy) {
    const int truesize = s->bytes + 2048;
    struct sock sk={
        .net.ipv4.sysctl_tcp_autocorking=policy,
        .tail={s->bytes,truesize,s->collapsible},.rtx_empty=!s->in_rtx,
        .sk_tsq_flags=s->already_throttled,
        .sk_wmem_alloc.samples={truesize+s->extra_first,truesize+s->extra_second}
    };
    tcp_push(&sk,0,1460,1,s->goal);
    printf("%s %d %d %d %d %d %d %d %d %d %u %u %u %d\n",s->name,policy,s->bytes,s->goal,
           s->in_rtx,truesize,sk.sk_wmem_alloc.samples[0],sk.sk_wmem_alloc.samples[1],
           s->already_throttled,s->collapsible,sk.push_calls,sk.net.autocork_events,
           sk.sk_tsq_flags,sk.sk_wmem_alloc.reads);
}

int main(void) {
    const struct state states[]={
        {"fresh-17-empty",17,1460,false,0,0,false,true},
        {"fresh-17-empty-despite-extra-charge",17,1460,false,4096,4096,false,true},
        {"reused-17-prior-in-flight",17,1460,true,4096,4096,false,true},
        {"bulk-partial-prior-in-flight",32000,64000,true,65536,65536,false,true},
        {"bulk-full-goal",64000,64000,true,65536,65536,false,true},
        {"bulk-partial-charge-at-threshold",32000,64000,true,0,0,false,true},
        {"bulk-partial-completion-race",32000,64000,true,65536,0,false,true},
        {"bulk-partial-already-throttled",32000,64000,true,65536,65536,true,true},
        {"bulk-partial-noncollapsible",32000,64000,true,65536,65536,false,false},
        {"bulk-partial-prior-acked",32000,64000,false,65536,65536,false,true}
    };
    for(unsigned i=0;i<sizeof(states)/sizeof(states[0]);i++)
        for(unsigned j=0;j<2;j++) run(&states[i],(int)((i^j^1)&1));
}
