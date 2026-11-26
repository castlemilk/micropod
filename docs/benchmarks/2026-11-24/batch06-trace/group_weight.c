/* Fixed runqueue state for the original Linux 7.3.5 fair-scheduler functions. */
#include <assert.h>
#include <stdio.h>

#define SCHED_CAPACITY_SHIFT 10
#define SCHED_FIXEDPOINT_SHIFT 10
#define READ_ONCE(v) (v)
#define min(a,b) ((a) < (b) ? (a) : (b))
#define max(a,b) ((a) > (b) ? (a) : (b))
#define clamp_t(t,x,lo,hi) ((t)min(max((t)(x),(t)(lo)),(t)(hi)))
#define atomic_long_read(ptr) (*(ptr))

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
static int numa_online = 4;
static int num_online_cpus(void) { return numa_online; }
static int cpusets_enabled(void) { return 1; }
static int cpuset_num_cpus(struct cgroup *g) { return g->cpus; }

#include "group_weight.inc"

/* All runnable tasks have nice-0 load. Runqueues are in a steady PELT state,
 * each task contributes 1024, and CPU0 contains the ceiling of tasks/4. */
static long weight_on_cpu0(int tasks, int mode) {
    int local_tasks = (tasks + 3) / 4;
    struct cgroup cpus = {.cpus = 4};
    struct task_group tg = {.shares = scale_load(1024L), .load_avg = tasks * 1024L,
                            .runnable_avg = tasks * 1024L, .css.cgroup = &cpus};
    struct cfs_rq rq = {.tg = &tg, .load.weight = scale_load(local_tasks * 1024UL),
                        .avg.load_avg = local_tasks * 1024UL,
                        .tg_load_avg_contrib = local_tasks * 1024L};
    return mode == 0 ? calc_concur_shares(&rq) : calc_tasks_shares(&rq);
}

int main(void) {
    const int cases[][2] = {{1,1},{4,1},{8,1},{32,1},{1,8},{1,32},{32,32}};
    for (unsigned i=0; i < sizeof(cases)/sizeof(*cases); ++i) {
        for (int mode=0; mode <= 1; ++mode) {
            long service = weight_on_cpu0(cases[i][0], mode);
            long sibling = weight_on_cpu0(cases[i][1], mode);
            assert(service > 0 && sibling > 0);
            printf("%d %d %d %ld %ld\n", cases[i][0], cases[i][1], mode, service, sibling);
        }
    }
}
