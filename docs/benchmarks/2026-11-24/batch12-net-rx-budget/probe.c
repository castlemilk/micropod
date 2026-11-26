// SPDX-License-Identifier: GPL-2.0
#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>

typedef unsigned long ulong;
enum { HZ = 250, USEC_PER_SEC = 1000000, EINVAL = 22, proc_dointvec_minmax = 1 };
#define SYSCTL_KERN_TO_USER(dir) (!(dir))
#define WRITE_ONCE(x, v) ((x) = (v))
#define READ_ONCE(x) (x)
#define unlikely(x) (x)
#define usecs_to_jiffies _usecs_to_jiffies
#define time_after_eq(a, b) ((long)((a) - (b)) >= 0)

struct ctl_table {
    const char *procname;
    void *data;
    unsigned int maxlen;
    int mode, proc_handler;
    void *extra1, *extra2;
};

/* Identical owners need only a cardinality. A poll removes one from the
 * active list, with a saturated owner returning once on the repoll list. */
struct list_head { unsigned count; };
struct napi_struct { struct list_head *queued_in; };
#define LIST_HEAD(name) struct list_head name = {0}
#define list_empty(head) ((head)->count == 0)
#define list_first_entry(head, type, member) (&(type){.queued_in = (head)})

static void list_splice(struct list_head *from, struct list_head *to)
{
    to->count += from->count;
}

static void list_splice_init(struct list_head *from, struct list_head *to)
{
    list_splice(from, to);
    from->count = 0;
}

#define list_splice_tail list_splice
#define list_splice_tail_init list_splice_init
struct softnet_data {
    struct list_head poll_list;
    unsigned time_squeeze;
    bool in_net_rx_action;
};
static struct softnet_data softnet_data;
struct bpf_net_context { unsigned unused; };
#define __latent_entropy
#define this_cpu_ptr(pointer) (pointer)
#define bpf_net_ctx_set(pointer) (pointer)
#define bpf_net_ctx_clear(pointer) ((void)(pointer))
#define local_irq_disable() ((void)0)
#define local_irq_enable() ((void)0)
#define skb_defer_free_flush() ((void)0)
#define barrier() ((void)0)
#define sd_has_rps_ipi_waiting(sd) false
#define net_rps_action_and_irq_enable(sd) ((void)(sd))
#define __raise_softirq_irqoff(kind) (++event.reraises)

static unsigned long jiffies, simulated_us;
static struct { unsigned poll_us, work, polls, reraises; } event;
static int napi_poll(struct napi_struct *owner, struct list_head *repoll)
{
    assert(owner->queued_in->count && event.polls < 32);
    owner->queued_in->count--;
    if (event.work == 64)
        repoll->count++;
    event.polls++;
    simulated_us += event.poll_us;
    jiffies = simulated_us / (USEC_PER_SEC / HZ);
    return (int)event.work;
}

#include "rx.inc"

int main(void)
{
    const struct workload {
        const char *name;
        unsigned start_us, work, poll_us, owners;
    } cases[] = {
        {"time_aligned", 0, 1, 1000, 32}, {"time_late_in_tick", 3500, 1, 1000, 32},
        {"packet_bound", 0, 64, 100, 16}, {"long_poll", 0, 1, 12000, 1},
        {"one_saturated_owner", 0, 64, 100, 1}, {"one_light_owner", 0, 1, 100, 1}
    };
    const int requests[] = {2000, 4000, 7999, 8000, 8001, 12000};
    const int stock = net_hotdata.netdev_budget_usecs;
    assert(stock == netdev_budget_usecs_min && stock == 8000 && net_hotdata.netdev_budget == 300);

    puts("case requested_us write_result readback_us ticks initial_owners work_per_poll poll_us start_us polls work_done elapsed_us squeeze remaining_owners reraised");
    for (size_t q = 0; q < sizeof(requests) / sizeof(*requests); q++) {
        net_hotdata.netdev_budget_usecs = stock;
        bool neg = false;
        unsigned long value = (unsigned long)requests[q];
        int rc = do_proc_int_conv_minmax(&neg, &value, entry.data, 1, &entry);
        unsigned long readback = 0;
        assert(do_proc_int_conv_minmax(&neg, &readback, entry.data, 0, &entry) == 0);
        for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
            const struct workload *w = &cases[i];
            softnet_data = (struct softnet_data){.poll_list = {.count = w->owners}};
            simulated_us = w->start_us;
            jiffies = simulated_us / (USEC_PER_SEC / HZ);
            event.polls = event.reraises = 0;
            event.poll_us = w->poll_us;
            event.work = w->work;
            net_rx_action();
            printf("%s %d %d %lu %lu %u %u %u %u %u %u %lu %u %u %u\n",
                   w->name, requests[q], rc, readback, _usecs_to_jiffies((unsigned)readback),
                   w->owners, w->work, w->poll_us, w->start_us,
                   event.polls, event.polls * event.work, simulated_us - w->start_us,
                   softnet_data.time_squeeze, softnet_data.poll_list.count, event.reraises);
        }
    }
}
