/* SPDX-License-Identifier: GPL-2.0 */
/* The caller provides one synthetic steady-state group runqueue at a time. */
#include <stdio.h>

#define SCHED_CAPACITY_SHIFT 10
#define SCHED_FIXEDPOINT_SHIFT 10
#define READ_ONCE(x) (x)
#define atomic_long_read(p) (*(p))
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))
#define clamp_t(t, x, lo, hi) min(max((t)(x), (t)(lo)), (t)(hi))
#define DEFINE_STATIC_CALL(name, fn) static long (*name)(struct cfs_rq *) = (fn)
#define static_call_update(name, fn) ((name) = (fn))

struct cgroup { int cpus; };
struct task_group {
    long shares, load_avg, runnable_avg;
    struct { struct cgroup *cgroup; } css;
};
struct cfs_rq {
    struct task_group *tg;
    struct { unsigned long weight; } load;
    struct { unsigned long load_avg; } avg;
    long tg_load_avg_contrib;
};
static int num_online_cpus(void) { return 4; }
static int cpusets_enabled(void) { return 1; }
static int cpuset_num_cpus(struct cgroup *cg) { return cg->cpus; }

#include "kernel.inc"

int main(void) {
    int mode, cpus, total, local;
    long base;
    while (scanf("%d%d%ld%d%d", &mode, &cpus, &base, &total, &local) == 5) {
        if ((mode != 2 && mode != 3) || cpus < 1 || cpus > 4 ||
            total < 1 || total > 32 || local < 1 || local > total || base < 1 || base > 32768)
            return 1;
        long unit = sched_prio_to_weight[20];
        struct cgroup cg = { .cpus = cpus };
        struct task_group tg = { .shares = scale_load(base), .load_avg = total * unit,
            .runnable_avg = total << SCHED_CAPACITY_SHIFT, .css.cgroup = &cg };
        struct cfs_rq rq = { .tg = &tg, .load.weight = scale_load((unsigned long)local * unit),
            .avg.load_avg = local * unit, .tg_load_avg_contrib = local * unit };
        __sched_cgroup_mode_update(mode);
        printf("%ld\n", calc_group_shares(&rq));
    }
    return feof(stdin) ? 0 : 1;
}
