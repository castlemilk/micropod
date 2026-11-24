#include "fq_shim.h"
#include "fq_functions.inc"

/* Recompute the ones'-complement checksum directly over all ten network-order words. */
static u16 folded(const struct iphdr *ip) {
    const unsigned char *p=(const unsigned char*)ip;
    u32 sum=0;
    for(unsigned int i=0;i<sizeof(*ip);i+=2) sum+=(p[i]<<8)|p[i+1];
    while(sum>>16) sum=(sum&65535)+(sum>>16);
    return (u16)sum;
}

static void run(bool enable, unsigned ecn, unsigned late_ns) {
    struct Qdisc sch={.limit=256}; struct fq_sched_data *q=&sch.state;
    q->quantum=3028; q->initial_quantum=15140; q->flow_plimit=100;
    q->rate_enable=1; q->flow_max_rate=~0UL; q->time_next_delayed_flow=~0ULL;
    q->ce_threshold=enable ? 2000000ULL : 1000ULL*UINT32_MAX;
    q->horizon=10000000000ULL;
    for(int b=0;b<FQ_BANDS;b++) q->band_flows[b].credit=q->band_flows[b].quantum=589824;
    struct sock sockets[2]={{.sk_hash=1},{.sk_hash=2}};
    struct sk_buff ongoing={.sk=&sockets[0],.tstamp=mono_ns,.time_to_send=mono_ns,.tag='O',.len=1514};
    struct fq_flow bg={.sk=&sockets[0],.socket_hash=1,.credit=3028,.head=&ongoing,
                       .tail=&ongoing,.qlen=1};
    sch.q.qlen=q->band_pkt_count[0]=1; q->flows=1; fq_flow_add_tail(q,&bg,OLD_FLOW);
    struct iphdr ip={.version_ihl=0x45,.tos=(u8)(0x28 | ecn),.len=htons(1500),.id=htons(0x1234),
                     .frag=htons(0x4000),.ttl=64,.proto=6,.src=htonl(0xc0000201),.dst=htonl(0xc6336401)};
    ip.check=htons((u16)~folded(&ip));
    assert(folded(&ip)==0xffff);
    unsigned old_check=ntohs(ip.check);
    struct sk_buff sample={.sk=&sockets[1],.tstamp=mono_ns-late_ns,.len=1514,
                           .network=(unsigned char*)&ip};
    assert(fq_enqueue(&sample,&sch,NULL)==NET_XMIT_SUCCESS);
    struct fq_flow *flow=fq_classify(&sch,&sample,mono_ns);
    assert(fq_dequeue(&sch)==&sample && (ip.tos&0xfc)==0x28 && folded(&ip)==0xffff);
    printf("%d %u %u %u %u %u %u %u %u\n",enable,ecn,late_ns,ip.tos&3,
           q->stat_ce_mark,old_check,ntohs(ip.check),folded(&ip),sample.len);
    assert(fq_dequeue(&sch)==&ongoing && !fq_dequeue(&sch) && !q->band_pkt_count[0]);
    free(flow);
}

int main(void) {
    const unsigned lag[]={1000000,2000000,2000001,4000000};
    for(unsigned ecn=0;ecn<4;ecn++) for(unsigned i=0;i<4;i++)
        for(unsigned arm=0;arm<2;arm++) run((arm^i^ecn)&1,ecn,lag[i]);
    return 0;
}
