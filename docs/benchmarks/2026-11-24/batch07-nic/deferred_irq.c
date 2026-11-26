// Sequential RX completion fixture. The integer clock advances only for a
// supplied arrival or an armed timer. No sleeping or real interfaces.
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { NAPI_STATE_SCHED=0, NAPI_STATE_PREFER_BUSY_POLL=7 };
enum { NAPIF_STATE_SCHED=1, NAPIF_STATE_MISSED=2, NAPIF_STATE_SCHED_THREADED=512,
       NAPIF_STATE_NPSVC=8, NAPIF_STATE_PREFER_BUSY_POLL=128, NAPIF_STATE_IN_BUSY_POLL=64 };
enum hrtimer_restart { HRTIMER_NORESTART=0 };
struct hrtimer { unsigned long expiration; };
struct gro { unsigned long bitmask; };
struct napi_struct {
    unsigned long state;
    int defer_hard_irqs_count, list_owner, poll_list;
    unsigned int defers;
    struct gro gro;
    struct hrtimer timer;
};
struct virtqueue { bool interrupt_enabled; };
static unsigned long clock_ns;
static int schedules;
#define unlikely(x) (x)
#define WARN_ON_ONCE(x) assert(!(x))
#define napi_get_gro_flush_timeout(n) (20000UL)
#define napi_get_defer_hard_irqs(n) ((int)(n)->defers)
#define gro_flush_normal(g,t) ((void)(g),(void)(t))
#define list_empty(p) (*(p)==0)
#define local_irq_save(f) ((f)=0)
#define local_irq_restore(f) ((void)(f))
#define list_del_init(p) abort()
#define WRITE_ONCE(v,n) ((v)=(n))
#define READ_ONCE(v) (v)
static bool try_cmpxchg(unsigned long *state, unsigned long *expected, unsigned long value) {
    assert(*state == *expected);
    *state = value;
    return true;
}
#define __napi_schedule(n) abort()
#define ns_to_ktime(t) (t)
#define HRTIMER_MODE_REL_PINNED 0
#define hrtimer_start(timer,offset,flags) ((timer)->expiration=clock_ns+(offset))
#define container_of(ptr,type,member) ((type*)((char*)(ptr)-offsetof(type,member)))
#define napi_disable_pending(n) false
static bool test_and_set_bit(int bit, unsigned long *state) {
    bool old = (*state & (1UL<<bit)) != 0;
    *state |= 1UL<<bit;
    return old;
}
#define clear_bit(bit,state) (*(state)&=~(1UL<<(bit)))
#define __napi_schedule_irqoff(n) (++schedules)
static int virtqueue_enable_cb_prepare(struct virtqueue *v) { v->interrupt_enabled=true; return 0; }
#define virtqueue_poll(v,o) ((void)(v),(void)(o),false)
#define virtqueue_napi_schedule(n,v) abort()
static void virtqueue_disable_cb(struct virtqueue *v) { v->interrupt_enabled=false; }
#include "linux_functions.inc"

static void run(const char *name, int spacing_us, int count, int defers) {
    struct napi_struct napi={.defers=(unsigned int)defers};
    struct virtqueue queue={.interrupt_enabled=true};
    unsigned long arrived_ns[64], waits_ns[64], next_event, never=~0UL;
    int arrived=0, received=0, interrupts=0, timers=0, empty_polls=0;
    clock_ns=0;
    schedules=0;
    for (int i=0;i<count;i++) arrived_ns[i]=1000UL*(1+spacing_us*i);
    while (received<count || napi.timer.expiration) {
        unsigned long next_rx=arrived<count?arrived_ns[arrived]:never;
        unsigned long expiry=napi.timer.expiration?napi.timer.expiration:never;
        assert(next_rx!=never || expiry!=never);
        next_event=next_rx<expiry?next_rx:expiry;
        clock_ns=next_event;
        bool need_poll=false;
        if (next_rx==next_event) {
            while (arrived<count && arrived_ns[arrived]==clock_ns) arrived++;
            if (queue.interrupt_enabled) {
                interrupts++;
                queue.interrupt_enabled=false;
                assert(!(napi.state&NAPIF_STATE_SCHED));
                napi.state |= NAPIF_STATE_SCHED;
                need_poll=true;
            }
        }
        if (expiry==next_event) {
            napi.timer.expiration=0;
            int before=schedules;
            napi_watchdog(&napi.timer);
            if (schedules>before) { need_poll=true; timers++; }
        }
        if (need_poll) {
            int work=arrived-received;
            if (!work) empty_polls++;
            while (received<arrived) {
                waits_ns[received]=clock_ns-arrived_ns[received];
                ++received;
            }
            virtqueue_napi_complete(&napi,&queue,work);
        }
    }
    assert(received==count && queue.interrupt_enabled);
    printf("%s %d %d %d %d %d",name,defers,count,interrupts,timers,empty_polls);
    for (int i=0;i<count;i++) printf(" %lu",waits_ns[i]);
    putchar('\n');
}

int main(void) {
    const int spacing[]={0,1,19,20,21,50,25000};
    const char *names[]={"one_burst","dense_1us","below_timer","at_timer","above_timer","idle_gap","fresh_period"};
    for (int i=0;i<7;i++)
        for (int d=0;d<=2;d+=2) run(names[i],spacing[i],32,d);
    return 0;
}
