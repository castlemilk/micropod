#include "fq_shim.h"
#include "fq_functions.inc"

enum { ONGOING = 64, RETURNING = 6 };
static void put(struct Qdisc *sch, struct sock *sock, struct sk_buff *skb,
                char tag, int seq, int bytes) {
    *skb=(struct sk_buff){.sk=sock,.tstamp=mono_ns,.len=bytes,.tag=tag,.seq=seq};
    assert(fq_enqueue(skb,sch,NULL)==NET_XMIT_SUCCESS);
}

static void run(int delay_ticks, int idle_ticks, int len) {
    struct Qdisc sch={.limit=256};
    struct fq_sched_data *q=&sch.state;
    q->quantum=3028; q->initial_quantum=15140; q->flow_plimit=100;
    q->flow_refill_delay=delay_ticks; q->rate_enable=1; q->flow_max_rate=~0UL;
    q->time_next_delayed_flow=~0ULL; q->ce_threshold=~0ULL>>1;
    q->horizon=10000000000ULL;
    for(int b=0;b<FQ_BANDS;b++) q->band_flows[b].credit=q->band_flows[b].quantum=589824;
    struct sock socks[3]={{.sk_hash=1},{.sk_hash=2},{.sk_hash=3}};
    struct sk_buff ongoing[ONGOING], first, burst[RETURNING], marker;
    struct fq_flow bg={.sk=&socks[0],.socket_hash=1,.credit=3028,.head=ongoing,
                       .tail=&ongoing[ONGOING-1],.qlen=ONGOING};
    for(int i=0;i<ONGOING;i++)
        ongoing[i]=(struct sk_buff){.sk=&socks[0],.tstamp=mono_ns,.time_to_send=mono_ns,
            .len=1514,.tag='O',.seq=i,.next=i+1<ONGOING?&ongoing[i+1]:NULL};
    sch.q.qlen=q->band_pkt_count[0]=ONGOING; q->flows=1;
    fq_flow_add_tail(q,&bg,OLD_FLOW);
    jiffies=101;
    put(&sch,&socks[1],&first,'W',0,15000);
    struct fq_flow *returner=fq_classify(&sch,&first,mono_ns);
    assert(fq_dequeue(&sch)==&first);
    int old_seen=0;
    while(!fq_flow_is_detached(returner)) {
        struct sk_buff *skb=fq_dequeue(&sch);
        assert(skb && skb->tag=='O' && skb->seq==old_seen++);
    }
    assert(returner->age==jiffies && returner->credit==140);
    jiffies+=idle_ticks;
    mono_ns+=4000000ULL*idle_ticks;
    int credit_before=returner->credit;
    for(int i=0;i<RETURNING;i++) put(&sch,&socks[1],&burst[i],'R',i,len);
    int credit_on_resume=returner->credit;
    put(&sch,&socks[2],&marker,'F',0,256);
    struct fq_flow *fresh=fq_classify(&sch,&marker,mono_ns);
    int returned=0,marked=0;
    printf("%d %d %d %d %d %d ",delay_ticks,idle_ticks,len,credit_before,credit_on_resume,old_seen);
    struct sk_buff *skb;
    while((skb=fq_dequeue(&sch))) {
        putchar(skb->tag);
        if(skb->tag=='O') assert(skb->seq==old_seen++);
        else if(skb->tag=='R') assert(skb->seq==returned++);
        else {assert(skb==&marker); marked++;}
    }
    putchar('\n');
    assert(old_seen==ONGOING && returned==RETURNING && marked==1 && !q->band_pkt_count[0]);
    free(returner); free(fresh);
}
int main(void) {
    const int waits[]={1,2,10,11}, sizes[]={1514,64512};
    for(unsigned i=0;i<4;i++) for(unsigned s=0;s<2;s++)
        for(unsigned a=0;a<2;a++) run((a^i^s)&1?1:10,waits[i],sizes[s]);
    return 0;
}
