/* SPDX-License-Identifier: GPL-2.0 */
#define MIN_SHARES		(1UL <<  1)
# define scale_load(w)		((w) << SCHED_FIXEDPOINT_SHIFT)
# define scale_load_down(w)					\
({								\
	unsigned long __w = (w);				\
								\
	if (__w)						\
		__w = max(2UL, __w >> SCHED_FIXEDPOINT_SHIFT);	\
	__w;							\
})
static long __calc_smp_shares(struct cfs_rq *cfs_rq, long tg_shares, long shares_max)
{
	struct task_group *tg = cfs_rq->tg;
	long tg_weight, load, shares;

	load = max(scale_load_down(cfs_rq->load.weight), cfs_rq->avg.load_avg);

	tg_weight = atomic_long_read(&tg->load_avg);

	/* Ensure tg_weight >= load */
	tg_weight -= cfs_rq->tg_load_avg_contrib;
	tg_weight += load;

	shares = (tg_shares * load);
	if (tg_weight)
		shares /= tg_weight;

	/*
	 * MIN_SHARES has to be unscaled here to support per-CPU partitioning
	 * of a group with small tg->shares value. It is a floor value which is
	 * assigned as a minimum load.weight to the sched_entity representing
	 * the group on a CPU.
	 *
	 * E.g. on 64-bit for a group with tg->shares of scale_load(15)=15*1024
	 * on an 8-core system with 8 tasks each runnable on one CPU shares has
	 * to be 15*1024*1/8=1920 instead of scale_load(MIN_SHARES)=2*1024. In
	 * case no task is runnable on a CPU MIN_SHARES=2 should be returned
	 * instead of 0.
	 */
	return clamp_t(long, shares, MIN_SHARES, shares_max);
}
static int tg_cpus(struct task_group *tg)
{
	int nr = num_online_cpus();

	if (cpusets_enabled()) {
		struct cgroup *cgrp = tg->css.cgroup;
		if (cgrp)
			nr = cpuset_num_cpus(cgrp);
	}

	/*
	 * An empty cpuset would propagate a 0 shares_max into
	 * __calc_smp_shares(), where clamp() yields hi when hi < lo and so
	 * defeats the MIN_SHARES floor. Match tg_tasks(), which floors at 1.
	 */
	return max(nr, 1);
}
static inline int tg_tasks(struct task_group *tg)
{
	return max(1, atomic_long_read(&tg->runnable_avg) >> SCHED_CAPACITY_SHIFT);
}
static long calc_tasks_shares(struct cfs_rq *cfs_rq)
{
	struct task_group *tg = cfs_rq->tg;
	int nr = tg_tasks(tg);
	long tg_shares = READ_ONCE(tg->shares);
	return __calc_smp_shares(cfs_rq, nr * tg_shares, nr * tg_shares);
}
static long calc_concur_shares(struct cfs_rq *cfs_rq)
{
	struct task_group *tg = cfs_rq->tg;
	int nr = min(tg_tasks(tg), tg_cpus(tg));
	long tg_shares = READ_ONCE(tg->shares);
	return __calc_smp_shares(cfs_rq, nr * tg_shares, nr * tg_shares);
}
