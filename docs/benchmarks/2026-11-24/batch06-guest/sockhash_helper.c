// Pinned Linux sk_redirect_hash helper plus minimal in-memory socket map.
#include <stdint.h>
#include <stddef.h>
struct sock {int cookie;};
struct sk_buff {int target;};
struct bpf_map {int present;};
typedef uint64_t u64;
enum {SK_DROP=0,SK_PASS=1,BPF_F_INGRESS=1};
#define BPF_CALL_4(name,t1,a,t2,b,t3,c,t4,d) int name(t1 a,t2 b,t3 c,t4 d)
#define unlikely(expr) (expr)
static struct sock sockets[2] = {{11},{22}};
static struct sock *__sock_hash_lookup_elem(struct bpf_map *map,void *key) {
    for(int j=0;j<2;j++) if ((map->present & (1<<j)) && sockets[j].cookie==*(int*)key) return &sockets[j];
    return NULL;
}
static int sock_map_redirect_allowed(struct sock *sk) { (void)sk; return 1; }
static int sk_is_vsock(struct sock *sk) { (void)sk; return 0; }
static void skb_bpf_set_redir(struct sk_buff *skb,struct sock *sk,unsigned flags) { (void)flags; skb->target=sk->cookie; }
#include "redirect_hash.inc"
int try_target(int mask,int peer) {
    struct sk_buff skb={0};
    struct bpf_map map={mask};
    int verdict=bpf_sk_redirect_hash(&skb,&map,&peer,0);
    return verdict==SK_DROP ? -1 : skb.target;
}
