#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <sys/types.h>

typedef uint32_t u32;
typedef int64_t s64;
enum { VIRTIO_VSOCK_MAX_PKT_BUF_SIZE=65536, MAX_PAYLOAD=1024*1024, MAX_PACKETS=1024 };
struct virtio_vsock_hdr {u32 len, buf_alloc, fwd_cnt;};
struct sk_buff {size_t len; unsigned int offset; struct virtio_vsock_hdr hdr; const unsigned char *data;};
struct packet_queue {struct sk_buff data[MAX_PACKETS]; size_t start, end;};
struct virtio_vsock_sock {
    u32 rx_bytes,buf_used,fwd_cnt,last_fwd_cnt,buf_alloc,peer_buf_alloc,peer_fwd_cnt,tx_cnt,bytes_unsent;
    struct packet_queue rx_queue;
};
struct vsock_sock {struct virtio_vsock_sock *trans;};
struct iov_iter {unsigned char *next;};
struct msghdr {struct iov_iter msg_iter;};
#define spin_lock_bh(p) ((void)0)
#define spin_unlock_bh(p) ((void)0)
#define WARN_ONCE(x,...) (x)
#define min(a,b) ((a)<(b)?(a):(b))
#define min_t(t,a,b) min((t)(a),(t)(b))
#define cpu_to_le32(x) (x)
#define le32_to_cpu(x) (x)
#define virtio_vsock_hdr(s) (&(s)->hdr)
#define VIRTIO_VSOCK_SKB_CB(s) (s)
#define skb_queue_empty(q) ((q)->start==(q)->end)
#define skb_peek(q) (&(q)->data[(q)->start])
#define __skb_unlink(s,q) ((q)->start++)
#define consume_skb(s) ((void)0)
#define sock_rcvlowat(s,a,b) 1U
static struct virtio_vsock_sock sender;
static unsigned updates;
static int virtio_transport_send_credit_update(struct vsock_sock *vsk);
static int skb_copy_datagram_iter(struct sk_buff *s,unsigned offset,struct iov_iter *iter,size_t n) {
    assert(offset+n<=s->len);memcpy(iter->next,s->data+offset,n);iter->next+=n;return 0;
}
#include "code.inc"
static int virtio_transport_send_credit_update(struct vsock_sock *vsk) {
    struct sk_buff packet={0};virtio_transport_inc_tx_pkt(vsk->trans,&packet);
    sender.peer_fwd_cnt=packet.hdr.fwd_cnt;sender.peer_buf_alloc=packet.hdr.buf_alloc;
    updates++;return 0;
}
static unsigned char input[MAX_PAYLOAD],output[MAX_PAYLOAD];
static void run(unsigned window,unsigned packet,unsigned read_size) {
    struct virtio_vsock_sock receiver={.buf_alloc=window}; struct vsock_sock local={&receiver};
    sender=(struct virtio_vsock_sock){.buf_alloc=window,.peer_buf_alloc=window};
    size_t sent=0,done=0,first=0,largest=0,last=0,waiting=0;
    updates=0;memset(output,0,sizeof(output));
    while(done<sizeof(input)) {
        while(sent<sizeof(input)) {
            u32 allowed=virtio_transport_get_credit(&sender,min(packet,sizeof(input)-sent));
            if(!allowed) break;
            size_t i=receiver.rx_queue.end++;assert(i<MAX_PACKETS);
            receiver.rx_queue.data[i]=(struct sk_buff){.len=allowed,.hdr={.len=allowed},.data=input+sent};
            sender.bytes_unsent-=allowed;sent+=allowed;receiver.buf_used+=allowed;receiver.rx_bytes+=allowed;
            assert(receiver.buf_used<=window);
        }
        assert(receiver.rx_bytes>0);
        bool blocked=sent<sizeof(input) && virtio_transport_has_space(&sender)==0;
        unsigned before=updates;
        struct msghdr msg={.msg_iter={output+done}};
        ssize_t n=virtio_transport_stream_do_dequeue(&local,&msg,min(read_size,sizeof(output)-done));
        assert(n>0 && msg.msg_iter.next==output+done+n);
        done+=(size_t)n;
        if(blocked) waiting+=n;
        if(updates>before) {
            if(!first) first=done;
            largest=largest>done-last?largest:done-last;last=done;
        }
    }
    assert(!memcmp(input,output,sizeof(input)) && receiver.buf_used==0 && sender.peer_fwd_cnt==done);
    printf("{\"credit_window\":%u,\"packet_bytes\":%u,\"read_bytes\":%u,\"verified_bytes\":%zu,"
           "\"credit_messages\":%u,\"first_credit_after_read_bytes\":%zu,\"max_bytes_between_updates\":%zu,"
           "\"receiver_bytes_read_while_sender_credit_exhausted\":%zu}\n",
        window,packet,read_size,done,updates,first,largest,waiting);
}
int main(void) {
    for(size_t i=0;i<sizeof(input);i++) input[i]=(i*17+i/31+13)%251;
    run(65536,4096,4096);run(262144,4096,4096);
    run(262144,16384,4096);run(262144,16384,65536);
    return 0;
}
