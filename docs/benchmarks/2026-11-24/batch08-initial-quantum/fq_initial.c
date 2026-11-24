/* Linux classifies the two new sockets and schedules every packet. Model one
 * eligible band, ordered FIFO packets, unbounded pacing and an older flow. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint64_t u64;
typedef int64_t s64;
typedef uint32_t u32;
enum new_flow { NEW_FLOW, OLD_FLOW };
enum { FQ_BANDS = 3, TCP_CLOSE = 7, SK_PACING_FQ = 2 };
struct rb_node { struct rb_node *rb_left, *rb_right; };
struct rb_root { struct rb_node *rb_node; };
struct sock { int sk_state, sk_pacing_status; u32 sk_hash; unsigned long sk_pacing_rate; };
struct sk_buff { void *dev; struct sock *sk; struct sk_buff *next; u64 tstamp,time_to_send; int band,len,seq; char tag; };
struct fq_flow {
    struct rb_node fq_node; /* offset zero in this fixture's substitute lookup tree */
    struct sock *sk; struct sk_buff *head; struct fq_flow *next;
    u32 socket_hash; int credit,band,qlen; unsigned long age;
    u64 time_next_packet,stat_fastpath_packets;
};
struct fq_flow_head { struct fq_flow *first,*last; };
struct fq_perband_flows { struct fq_flow_head new_flows,old_flows; int credit,quantum; };
struct fq_sched_data {
    struct fq_perband_flows band_flows[FQ_BANDS];
    struct fq_flow internal; struct rb_root fq_root[1];
    u32 orphan_mask,band_nr,quantum,initial_quantum,flows,inactive_flows,low_rate_threshold;
    unsigned long flow_max_rate;
    u64 time_next_delayed_flow,offload_horizon,ce_threshold;
    int rate_enable,band_pkt_count[FQ_BANDS],stat_allocation_errors,stat_ce_mark,stat_pkts_too_long;
};
struct Qdisc { struct {unsigned qlen;} q; struct fq_sched_data state; };
#define qdisc_priv(sch) (&(sch)->state)
#define jiffies 100UL
#define READ_ONCE(x) (x)
#define smp_store_release(p,v) (*(p)=(v))
#define likely(x) (x)
#define unlikely(x) (x)
#define sk_listener_or_tw(sk) false
#define skb_get_hash(skb) (abort(),0U)
#define skb_orphan(skb) abort()
#define hash_ptr(p,n) 0
#define fq_gc(q,root,sk) ((void)0)
#define rb_entry(ptr,type,field) ((type*)(ptr))
#define rb_link_node(node,parent,slot) ((void)(parent),*(slot)=(node))
#define rb_insert_color(node,root) ((void)0)
#define kmem_cache_zalloc(pool,flags) calloc(1,sizeof(struct fq_flow))
#define fq_flow_is_throttled(f) false
#define fq_flow_unset_throttled(q,f) abort()
static bool fq_fastpath_check(struct Qdisc *sch, struct sk_buff *skb, u64 now) {
    (void)skb; (void)now;
    assert(sch->q.qlen && sch->state.flows > sch->state.inactive_flows);
    return false; /* an eligible flow is already pending */
}
#define fq_skb_cb(skb) (skb)
#define ktime_get_ns() 100ULL
#define fq_check_throttled(q,now) ((void)0)
#define qdisc_watchdog_schedule_range_ns(watchdog,ts,slack) abort()
#define fq_flow_set_throttled(q,f) abort()
#define prefetch(addr) ((void)0)
#define INET_ECN_set_ce(skb) abort()
#define qdisc_pkt_len(skb) ((skb)->len)
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define max_t(t,a,b) max((t)(a),(t)(b))
#define min_t(t,a,b) min((t)(a),(t)(b))
#define div64_ul(a,b) ((a)/(b))
#define NSEC_PER_SEC 1000000000ULL
#define skb_rb_first(tree) NULL
#define rb_erase(node,root) abort()
#define qdisc_dev(sch) ((void)(sch),NULL)
#define skb_mark_not_on_list(skb) ((skb)->next=NULL)
#define qdisc_qlen_dec(sch) (--(sch)->q.qlen)
#define qdisc_qstats_backlog_dec(sch,skb) ((void)0)
#define qdisc_bstats_update(sch,skb) ((void)0)
#include "fq_functions.inc"

static void supply(struct Qdisc *sch, struct fq_flow *flow, struct sock *sk,
                   struct sk_buff *packets, int count, int len, char tag) {
    assert(!flow->qlen && !flow->head);
    for (int i=0; i<count; ++i) {
        packets[i]=(struct sk_buff){.sk=sk,.next=i+1<count ? &packets[i+1] : NULL,
                                   .len=len,.tag=tag,.seq=i,.tstamp=1,.time_to_send=1};
    }
    flow->head=packets; flow->qlen=count;
    sch->q.qlen+=count; sch->state.band_pkt_count[0]+=count;
}

static struct fq_flow *new_flow(struct Qdisc *sch, struct sock *sk) {
    struct sk_buff first={.sk=sk};
    struct fq_flow *flow=fq_classify(sch,&first,ktime_get_ns());
    assert(flow && flow!=&sch->state.internal && flow->credit==(int)sch->state.initial_quantum);
    fq_flow_add_tail(&sch->state,flow,NEW_FLOW);
    --sch->state.inactive_flows;
    return flow;
}

static void run(int initial, int bulk_len, int before_fresh) {
    enum { BULK=32, OLD=32, FRESH_LEN=256 };
    struct Qdisc sch={0}; struct fq_sched_data *q=&sch.state;
    q->quantum=3028; q->initial_quantum=initial; q->rate_enable=1;
    q->flow_max_rate=~0UL; q->time_next_delayed_flow=~0ULL; q->ce_threshold=~0ULL>>1;
    const int band_quantum[]={589824,196608,65536};
    for (int i=0;i<FQ_BANDS;i++)
        q->band_flows[i].credit=q->band_flows[i].quantum=band_quantum[i];
    struct sock sockets[3]={{.sk_hash=1},{.sk_hash=2},{.sk_hash=3}};
    struct sk_buff old_packet[OLD],bulk_packet[BULK],fresh_packet;
    struct fq_flow old={.credit=(int)q->quantum}; q->flows=1;
    supply(&sch,&old,&sockets[0],old_packet,OLD,1514,'O');
    fq_flow_add_tail(q,&old,OLD_FLOW);
    struct fq_flow *bulk=new_flow(&sch,&sockets[1]), *fresh=NULL;
    supply(&sch,bulk,&sockets[1],bulk_packet,BULK,bulk_len,'B');
    printf("%d %d %d ",initial,bulk_len,before_fresh);
    int seen[3]={0};
    for (int i=0; i<OLD+BULK+1; i++) {
        if(i==before_fresh) {
            fresh=new_flow(&sch,&sockets[2]);
            supply(&sch,fresh,&sockets[2],&fresh_packet,1,FRESH_LEN,'F');
        }
        struct sk_buff *out=fq_dequeue(&sch); assert(out);
        int role=out->tag=='B'?1:out->tag=='O'?0:2;
        assert(out->seq==seen[role]++); putchar(out->tag);
    }
    putchar('\n');
    assert(!fq_dequeue(&sch) && seen[0]==OLD && seen[1]==BULK && seen[2]==1 && !q->band_pkt_count[0]);
    free(bulk); free(fresh);
}

int main(void) {
    const int sizes[]={1514,64512}, arrival[]={0,1,12}, initial[]={15140,3028};
    for(unsigned a=0;a<2;a++) for(unsigned b=0;b<3;b++)
        for(unsigned c=0;c<2;c++) run(initial[c],sizes[a],arrival[b]);
}
