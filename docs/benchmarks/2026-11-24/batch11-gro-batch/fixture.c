#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

struct list_head { struct list_head *prev, *next; };
struct sk_buff { struct list_head list; int id; };
struct gro_node { unsigned int bitmask; int rx_count; struct list_head rx_list; };
struct napi_struct {
    unsigned long state;
    struct gro_node gro;
    int defer_hard_irqs_count, list_owner;
    struct list_head poll_list;
};
static struct { int gro_normal_batch; } net_hotdata;
static int event, completing;

static void INIT_LIST_HEAD(struct list_head *head) { head->prev = head->next = head; }
static bool list_empty(struct list_head *head) { return head->next == head; }
static void list_add_tail(struct list_head *entry, struct list_head *head) {
    entry->next = head;
    entry->prev = head->prev;
    head->prev->next = entry;
    head->prev = entry;
}

static void netif_receive_skb_list_internal(struct list_head *head) {
    printf("%d %s", event, completing ? "complete" : "enqueue");
    for (struct list_head *p = head->next; p != head; p = p->next)
        printf(" %d", ((struct sk_buff *)p)->id);
    putchar('\n');
}

#define READ_ONCE(v) (v)
#define WRITE_ONCE(v, x) ((v) = (x))
#define WARN_ON_ONCE(b) assert(!(b))
#define unlikely(b) (b)
enum { NAPIF_STATE_SCHED = 1, NAPIF_STATE_NPSVC = 2, NAPIF_STATE_IN_BUSY_POLL = 4,
       NAPIF_STATE_MISSED = 8, NAPIF_STATE_SCHED_THREADED = 16, NAPIF_STATE_PREFER_BUSY_POLL = 32 };
#define napi_get_defer_hard_irqs(n) 0
#define napi_get_gro_flush_timeout(n) 0UL
#define __gro_flush(gro, old) do { (void)(old); abort(); } while (0)
#define local_irq_save(flags) do { (flags) = 0; abort(); } while (0)
#define local_irq_restore(flags) ((void)(flags))
#define list_del_init(entry) abort()
#define __napi_schedule(n) abort()
#define hrtimer_start(timer, time, mode) abort()

static bool try_cmpxchg(unsigned long *state, unsigned long *old, unsigned long value) {
    if (*state != *old) { *old = *state; return false; }
    *state = value;
    return true;
}

#include "linux-gro.inc"

int main(int argc, char **argv) {
    assert(argc >= 3 && argc <= 66);
    struct napi_struct napi = {.state = NAPIF_STATE_SCHED};
    struct sk_buff skbs[64] = {0};
    net_hotdata.gro_normal_batch = atoi(argv[1]);
    INIT_LIST_HEAD(&napi.gro.rx_list);
    INIT_LIST_HEAD(&napi.poll_list);
    int count = argc - 2;
    for (int i = 0; i < count; i++) {
        event = i + 1;
        skbs[i].id = event;
        gro_normal_one(&napi.gro, &skbs[i], atoi(argv[i + 2]));
    }
    completing = 1;
    assert(napi_complete_done(&napi, count));
    assert(list_empty(&napi.gro.rx_list) && !napi.gro.rx_count && !napi.state);
    return 0;
}
