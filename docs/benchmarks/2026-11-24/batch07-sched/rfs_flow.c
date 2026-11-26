// SPDX-License-Identifier: GPL-2.0
// A single-flow, four-CPU fixed-work fixture for the stock RPS/RFS selector.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
typedef uint16_t u16;
struct rps_dev_flow {u16 cpu; u32 last_qtail;};
struct rps_sock_flow_table {u32 ent;};
struct rps_map {unsigned len,cpus[4];};
typedef void *rps_tag_ptr;
struct netdev_rx_queue {rps_tag_ptr rps_flow_table; struct rps_map *rps_map;};
struct net_device {struct netdev_rx_queue *_rx; unsigned real_num_rx_queues;};
struct sk_buff {u32 hash;};
static struct {rps_tag_ptr rps_sock_flow_table; u32 rps_cpu_mask;} net_hotdata;
static struct {unsigned input_queue_head;} softnet_data[4];
#define nr_cpu_ids 4U
#define READ_ONCE(v) (v)
#define WRITE_ONCE(k,v) ((k)=(v))
#define per_cpu(arr,idx) ((arr)[idx])
#define cpu_online(n) ((n)<nr_cpu_ids)
#define skb_rx_queue_recorded(skb) 1
#define skb_get_rx_queue(skb) 0
#define skb_get_hash(skb) ((skb)->hash)
#define skb_reset_network_header(skb) ((void)(skb))
#define unlikely(c) (c)
#define WARN_ONCE(c,...) ((void)(c))
#define rcu_dereference(p) (p)
// Each fixed table contains one slot, with no concurrent mutations or hardware steering.
#define rfs_slot(hash,p) 0
#define rps_tag_to_mask(ptr) 0U
#define rps_tag_to_table(ptr) (ptr)
#define rps_input_queue_tail_save(addr,value) (*(addr)=(value))
#define reciprocal_scale(hash,len) ((u32)(((uint64_t)(hash)*(len))>>32))
#include "rfs_flow.inc"

enum { ARRIVALS=64, MAX_PACKETS=128 };
struct fifo {int ids[MAX_PACKETS],read,write;u32 tail;};
static int seen, selected[MAX_PACKETS], received[MAX_PACKETS];
static void pop(struct fifo queue[],int cpu,int allowance) {
    for (int j=0;j<allowance && queue[cpu].read<queue[cpu].write;j++) {
        received[seen++]=queue[cpu].ids[queue[cpu].read++];
        softnet_data[cpu].input_queue_head++;
    }
}
static void submit(struct net_device *dev,struct sk_buff *packet,struct fifo queue[],int seq) {
    struct rps_dev_flow *choice=NULL;
    int cpu=get_rps_cpu(dev,packet,&choice);
    assert(cpu>=0 && cpu<4 && queue[cpu].write<MAX_PACKETS);
    queue[cpu].ids[queue[cpu].write++]=seq;
    selected[seq]=cpu;
    ++queue[cpu].tail;
    if(choice) rps_input_queue_tail_save(&choice->last_qtail,queue[cpu].tail);
}
static void run(int enabled,int pending,int drain,int wraps) {
    struct rps_map map={.len=4,.cpus={0,1,2,3}};
    struct rps_dev_flow flow={.cpu=0xffff};
    struct rps_sock_flow_table socket_table;
    struct netdev_rx_queue rx={.rps_map=&map,.rps_flow_table=enabled?&flow:NULL};
    struct net_device dev={._rx=&rx,.real_num_rx_queues=1};
    struct sk_buff packet={.hash=0x11223344};
    socket_table.ent=packet.hash;
    net_hotdata.rps_sock_flow_table=&socket_table; net_hotdata.rps_cpu_mask=3;
    u32 start=wraps ? UINT32_MAX-5 : 0;
    struct fifo queue[4]={0};
    for(int c=0;c<4;c++) {softnet_data[c].input_queue_head=start;queue[c].tail=start;}
    seen=0;
    for (int i=0;i<pending;i++) submit(&dev,&packet,queue,i);
    socket_table.ent=(packet.hash&~3U)|3;  // recvmsg consumer moves from CPU 0 to 3.
    for(int i=0;i<ARRIVALS;i++) {
        pop(queue,0,drain);pop(queue,3,drain);
        submit(&dev,&packet,queue,pending+i);
    }
    for(int c=0;c<4;c++) pop(queue,c,MAX_PACKETS);
    assert(seen==ARRIVALS+pending);
    int on_reader=0;
    for(int i=0;i<seen;i++){assert(received[i]==i);if (i>=pending && selected[i]==3) on_reader++;}
    printf("{\"rfs\":%d,\"pending_at_migration\":%d,\"drain_per_cpu_per_arrival\":%d,\"counter_wrap\":%d,"
           "\"post_migration_cpu3_packets\":%d,\"in_order_packets\":%d,\"post_migration_cpu_sequence\":\"",enabled,pending,drain,wraps,on_reader,seen);
    for(int i=pending;i<seen;i++) putchar('0'+selected[i]);
    puts("\"}");
}
int main(void){
    const int pending[]={0,8,32};
    for(int wraps=0;wraps<2;wraps++) for(int p=0;p<3;p++) for(int drain=1;drain<=4;drain*=2)
        for(int rfs=0;rfs<2;rfs++) run(rfs,pending[p],drain,wraps);
}
