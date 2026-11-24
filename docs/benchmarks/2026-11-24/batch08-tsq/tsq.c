/* Supply fixed socket allocation readbacks to the unmodified Linux predicate. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint64_t u64;
struct sk_buff { unsigned truesize; };
struct counts { unsigned first, second, reads; };
struct sock {
    unsigned long sk_pacing_rate;
    unsigned sk_pacing_shift, tcp_tx_delay, rtx_entries, sk_tsq_flags;
    struct counts sk_wmem_alloc;
    struct { struct {unsigned sysctl_tcp_limit_output_bytes;} ipv4; } net;
};
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
#define max_t(t,a,b) ((t)(a)>(t)(b)?(t)(a):(t)(b))
#define READ_ONCE(x) (x)
#define sock_net(sk) (&(sk)->net)
#define tcp_sk(sk) (sk)
static bool tcp_tx_delay_enabled=false;
#define static_branch_unlikely(ptr) (*(ptr))
#define TSQ_THROTTLED 0
#define set_bit(bit,flags) (*(flags) |= 1u << (bit))
#define smp_mb__after_atomic() ((void)0)
#define tcp_rtx_queue_empty_or_single_skb(sk) ((sk)->rtx_entries <= 1)
static unsigned refcount_read(struct counts *c) {
    assert(c->reads<2);
    return c->reads++==0?c->first:c->second;
}
#include "original.inc"

int main(void) {
    unsigned cap, true_size, first, second, rtx;
    unsigned long rate;
    while (scanf("%u %lu %u %u %u %u",&cap,&rate,&true_size,&first,&second,&rtx)==6) {
        struct sock sk={.sk_pacing_rate=rate,.sk_pacing_shift=10,.rtx_entries=rtx,
            .sk_wmem_alloc={.first=first,.second=second}};
        sk.net.ipv4.sysctl_tcp_limit_output_bytes=cap;
        struct sk_buff skb={.truesize=true_size};
        bool throttle=tcp_small_queue_check(&sk,&skb,0);
        printf("%u %u %u\n",throttle,sk.sk_wmem_alloc.reads,sk.sk_tsq_flags);
    }
    return 0;
}
