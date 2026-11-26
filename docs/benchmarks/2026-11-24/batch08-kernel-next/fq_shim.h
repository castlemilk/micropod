/* Single-band, eligible FIFO flows with fixed timestamps, no device or allocator failures. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef uint64_t u64;
typedef uint8_t u8;
typedef int64_t ktime_t;
typedef int64_t s64;
typedef uint32_t u32;
enum new_flow { NEW_FLOW, OLD_FLOW };
enum { FQ_BANDS = 3, TCP_CLOSE = 7, SK_PACING_FQ = 2 };
struct rb_node { struct rb_node *rb_left, *rb_right; };
struct rb_root { struct rb_node *rb_node; };
struct sock { int sk_state, sk_pacing_status; u32 sk_hash; unsigned long sk_pacing_rate; };
struct sk_buff { unsigned char *network; struct rb_node rbnode; int priority; void *dev; struct sock *sk; struct sk_buff *next; u64 tstamp,time_to_send; int band,len,seq; char tag; };
struct fq_flow {
    struct rb_node fq_node; /* offset zero in this fixture's substitute lookup tree */
    struct sock *sk; struct sk_buff *head; struct fq_flow *next;
    u32 socket_hash; int credit,band; u32 qlen; union {unsigned long age; struct sk_buff *tail;}; struct rb_root t_root;
    u64 time_next_packet,stat_fastpath_packets;
};
struct fq_flow_head { struct fq_flow *first,*last; };
struct fq_perband_flows { struct fq_flow_head new_flows,old_flows; int credit,quantum; };
struct fq_sched_data {
    struct fq_perband_flows band_flows[FQ_BANDS];
    struct fq_flow internal; struct rb_root fq_root[1];
    u32 flow_plimit,flow_refill_delay,stat_flows_plimit,
        stat_band_drops[FQ_BANDS],stat_horizon_drops,stat_horizon_caps,horizon_drop;
    u64 horizon;
    u32 orphan_mask,band_nr,quantum,initial_quantum,flows,inactive_flows,low_rate_threshold;
    unsigned long flow_max_rate;
    u64 time_next_delayed_flow,offload_horizon,ce_threshold;
    int rate_enable,band_pkt_count[FQ_BANDS],stat_allocation_errors,stat_ce_mark,stat_pkts_too_long;
};
struct Qdisc {int limit; struct {unsigned qlen;} q; struct fq_sched_data state; };
#define qdisc_priv(sch) (&(sch)->state)
static unsigned long jiffies = 101;
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
static u64 mono_ns = 1000000000ULL;
#define ktime_get_ns() mono_ns
#define fq_check_throttled(q,now) ((void)0)
#define qdisc_watchdog_schedule_range_ns(watchdog,ts,slack) abort()
#define fq_flow_set_throttled(q,f) abort()
#define prefetch(addr) ((void)0)
#include "mark_hook.inc"
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

#define fq_prio2band(map, priority) 0
#define qdisc_drop_reason(skb,sch,to_free,why) ((void)(to_free),abort(),1)
#define time_after(current,deadline) ((long)((deadline)-(current))<0)
#define qdisc_qstats_backlog_inc(sch,skb) ((void)0)
#define qdisc_qlen_inc(sch) (++(sch)->q.qlen)
#define fq_skb_tstamp_to_mono(skb) ((ktime_t)(skb)->tstamp)
#define fq_mono_to_skb_tstamp(skb,stamp) ((skb)->tstamp=(stamp))
#define fq_flow_adjust_timer(q,f,time,now) abort()
#define rb_to_skb(ptr) (abort(),(struct sk_buff*)NULL)
#define NET_XMIT_SUCCESS 0
