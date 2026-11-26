#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
enum { PAGE_SIZE=4096, ZCRX_EVENT_COPY=1, IO_SKBS_PER_CALL_LIMIT=20 };
struct page { unsigned char data[PAGE_SIZE]; };
struct io_kiocb { int dummy; };
struct stats { size_t copy_count,copy_bytes; };
struct io_zcrx_ifq { struct stats *notif_stats; };
struct page_pool { const int *mp_ops; struct io_zcrx_ifq *ifq; };
struct net_iov { struct {struct page_pool *pp;} desc; struct page *page; int refs, urefs; };
typedef struct { struct net_iov *netmem; struct page *page; unsigned off,len; } skb_frag_t;
struct skb_shared_info { int nr_frags; skb_frag_t frags[1]; };
struct sk_buff { unsigned len,head; unsigned char *data; struct skb_shared_info shi; struct sk_buff *next; };
struct io_zcrx_args { struct io_kiocb *req; struct io_zcrx_ifq *ifq; unsigned nr_skbs; bool stopped_early; };
typedef struct { struct { void *data; } arg; size_t count; } read_descriptor_t;
static const int io_uring_pp_zc_ops=1;
static struct page head_page,fragment_page,fallback_pages[3];
static struct net_iov fallbacks[3];
static size_t fallback_used,copied;
static struct {struct net_iov *iov; unsigned off,len;} cqe[3];
static unsigned completions;
static struct net_iov *io_alloc_fallback_niov(struct io_zcrx_ifq *q) {
    (void)q; assert(fallback_used<3); return &fallbacks[fallback_used++];
}
static bool io_zcrx_queue_cqe(struct io_kiocb *req,struct net_iov *iov,struct io_zcrx_ifq *ifq,unsigned off,unsigned len) {
    (void)req; (void)ifq; assert(completions<3 && off+len<=PAGE_SIZE);
    cqe[completions].iov=iov; cqe[completions].off=off; cqe[completions++].len=len; return true;
}
static void *measured_copy(void *dst,const void *src,size_t n) { copied+=n; return memcpy(dst,src,n); }
#define min(a,b) ((a)<(b)?(a):(b))
#define min_t(t,a,b) min((t)(a),(t)(b))
#define unlikely(x) (x)
#define WARN_ON(x) (x)
#define folio_test_partial_kmap(x) false
#define kmap_local_page(p) ((p)->data)
#define kunmap_local(x) ((void)0)
#define io_zcrx_iov_page(i) ((i)->page)
#define io_zcrx_return_niov(i) ((void)0)
#define io_zcrx_get_niov_uref(i) ((i)->urefs++)
#define skb_frag_page(f) ((f)->page)
#define skb_frag_off(f) ((f)->off)
#define skb_frag_size(f) ((f)->len)
#define zcrx_stat_add(p,val) (*(p)+=(val))
#define zcrx_send_notif(q,event) ((void)0)
#define skb_frag_is_net_iov(f) ((f)->netmem!=NULL)
#define netmem_to_net_iov(n) (n)
#define net_iov_to_netmem(n) (n)
#define io_pp_to_ifq(p) ((p)->ifq)
#define page_pool_ref_netmem(n) ((n)->refs++)
#define skb_headlen(s) ((s)->head)
#define skb_shinfo(s) (&(s)->shi)
#define virt_to_page(x) (&head_page)
#define skb_walk_frags(s,it) for ((it)=(s)->next;(it);(it)=(it)->next)
/* Only one synthetic linear page is presented, at offset 0. */
#define offset_in_page(x) (0U)
#undef memcpy
#define memcpy measured_copy
#include "code.inc"
#undef memcpy

static void trial(bool registered,unsigned head,unsigned start,unsigned len) {
    struct stats s={0}; struct io_zcrx_ifq q={&s}; struct io_kiocb req={0};
    struct page_pool pp={&io_uring_pp_zc_ops,&q};
    struct net_iov direct={{&pp},&fragment_page,0,0};
    struct sk_buff skb={.len=4096,.head=head,.data=head_page.data};
    struct io_zcrx_args args={&req,&q,0,false};
    read_descriptor_t rd={.arg={&args},.count=len};
    unsigned char expected[4096], got[4096]; unsigned got_len=0;
    fallback_used=copied=completions=0;
    for(unsigned i=0;i<3;i++) fallbacks[i]=(struct net_iov){.page=&fallback_pages[i]};
    for(unsigned i=0;i<4096;i++) expected[i]=(i*29+i/79+71)%253;
    memcpy(head_page.data,expected,head);
    if(head<4096) {
        memcpy(fragment_page.data,expected+head,4096-head);
        skb.shi.nr_frags=1;skb.shi.frags[0]=(skb_frag_t){registered?&direct:NULL,&fragment_page,0,4096-head};
    }
    assert(io_zcrx_recv_skb(&rd,&skb,start,len)==(int)len && rd.count==0 && !args.stopped_early);
    for(unsigned i=0;i<completions;i++) {
        assert(cqe[i].iov->urefs>0);
        memcpy(got+got_len,cqe[i].iov->page->data+cqe[i].off,cqe[i].len);got_len+=cqe[i].len;
    }
    assert(got_len==len && memcmp(expected+start,got,len)==0);
    printf("{\"linear_bytes\":%u,\"start\":%u,\"verified_bytes\":%u,\"cqe\":%u,\"memcpy_bytes\":%zu,\"driver_copy_stat_bytes\":%zu,\"fallback_buffers\":%zu,\"provider_refs\":%d}\n",head,start,got_len,completions,copied,s.copy_bytes,fallback_used,direct.refs);
}
int main(int argc,char **argv) {
    assert(argc==2);bool r=!strcmp(argv[1],"candidate");
    trial(r,0,0,4096);trial(r,148,0,4096);trial(r,148,84,2000);trial(r,4096,0,4096);return 0;
}
