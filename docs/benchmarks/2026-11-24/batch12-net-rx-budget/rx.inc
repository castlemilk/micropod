/* SPDX-License-Identifier: GPL-2.0 */
/* Generated Linux 7.3.5 portions. See extract.py for paths and original blob IDs. */
static int netdev_budget_usecs_min = 2 * USEC_PER_SEC / HZ;
static struct { int netdev_budget, netdev_budget_usecs; } net_hotdata = {
	.netdev_budget = 300,
	.netdev_budget_usecs = 2 * USEC_PER_SEC / HZ,
};
static const struct ctl_table entry = {
.procname	= "netdev_budget_usecs",
		.data		= &net_hotdata.netdev_budget_usecs,
		.maxlen		= sizeof(unsigned int),
		.mode		= 0644,
		.proc_handler	= proc_dointvec_minmax,
		.extra1		= &netdev_budget_usecs_min,
};
int proc_int_k2u_conv_kop(ulong *u_ptr, const int *k_ptr, bool *negp,
			  ulong (*k_ptr_op)(const ulong))
{
	int val = READ_ONCE(*k_ptr);

	if (val < 0) {
		*negp = true;
		*u_ptr = k_ptr_op ? k_ptr_op(-(ulong)val) : -(ulong)val;
	} else {
		*negp = false;
		*u_ptr = k_ptr_op ? k_ptr_op((ulong)val) : (ulong) val;
	}
	return 0;
}
int proc_int_u2k_conv_uop(const ulong *u_ptr, int *k_ptr, const bool *negp,
			  ulong (*u_ptr_op)(const ulong))
{
	ulong u = u_ptr_op ? u_ptr_op(*u_ptr) : *u_ptr;

	if (*negp) {
		if (u > (ulong) INT_MAX + 1)
			return -EINVAL;
		WRITE_ONCE(*k_ptr, -u);
	} else {
		if (u > (ulong) INT_MAX)
			return -EINVAL;
		WRITE_ONCE(*k_ptr, u);
	}
	return 0;
}
int proc_int_conv(bool *negp, ulong *u_ptr, int *k_ptr, int dir,
		  const struct ctl_table *tbl, bool k_ptr_range_check,
		  int (*user_to_kern)(const bool *negp, const ulong *u_ptr, int *k_ptr),
		  int (*kern_to_user)(bool *negp, ulong *u_ptr, const int *k_ptr))
{
	if (SYSCTL_KERN_TO_USER(dir))
		return kern_to_user(negp, u_ptr, k_ptr);

	if (k_ptr_range_check) {
		int tmp_k, ret;

		if (!tbl)
			return -EINVAL;
		ret = user_to_kern(negp, u_ptr, &tmp_k);
		if (ret)
			return ret;
		if ((tbl->extra1 && *(int *)tbl->extra1 > tmp_k) ||
		    (tbl->extra2 && *(int *)tbl->extra2 < tmp_k))
			return -EINVAL;
		WRITE_ONCE(*k_ptr, tmp_k);
	} else
		return user_to_kern(negp, u_ptr, k_ptr);
	return 0;
}
static int sysctl_user_to_kern_int_conv(const bool *negp, const ulong *u_ptr,
					int *k_ptr)
{
	return proc_int_u2k_conv_uop(u_ptr, k_ptr, negp, NULL);
}
static int sysctl_kern_to_user_int_conv(bool *negp, ulong *u_ptr, const int *k_ptr)
{
	return proc_int_k2u_conv_kop(u_ptr, k_ptr, negp, NULL);
}
static int do_proc_int_conv_minmax(bool *negp, unsigned long *u_ptr, int *k_ptr,
				   int dir, const struct ctl_table *tbl)
{
	return proc_int_conv(negp, u_ptr, k_ptr, dir, tbl, true,
			     sysctl_user_to_kern_int_conv,
			     sysctl_kern_to_user_int_conv);
}
static inline unsigned long _usecs_to_jiffies(const unsigned int u)
{
	return (u + (USEC_PER_SEC / HZ) - 1) / (USEC_PER_SEC / HZ);
}
static __latent_entropy void net_rx_action(void)
{
	struct softnet_data *sd = this_cpu_ptr(&softnet_data);
	unsigned long time_limit = jiffies +
		usecs_to_jiffies(READ_ONCE(net_hotdata.netdev_budget_usecs));
	struct bpf_net_context __bpf_net_ctx, *bpf_net_ctx;
	int budget = READ_ONCE(net_hotdata.netdev_budget);
	LIST_HEAD(list);
	LIST_HEAD(repoll);

	bpf_net_ctx = bpf_net_ctx_set(&__bpf_net_ctx);
start:
	sd->in_net_rx_action = true;
	local_irq_disable();
	list_splice_init(&sd->poll_list, &list);
	local_irq_enable();

	for (;;) {
		struct napi_struct *n;

		skb_defer_free_flush();

		if (list_empty(&list)) {
			if (list_empty(&repoll)) {
				sd->in_net_rx_action = false;
				barrier();
				/* We need to check if ____napi_schedule()
				 * had refilled poll_list while
				 * sd->in_net_rx_action was true.
				 */
				if (!list_empty(&sd->poll_list))
					goto start;
				if (!sd_has_rps_ipi_waiting(sd))
					goto end;
			}
			break;
		}

		n = list_first_entry(&list, struct napi_struct, poll_list);
		budget -= napi_poll(n, &repoll);

		/* If softirq window is exhausted then punt.
		 * Allow this to run for 2 jiffies since which will allow
		 * an average latency of 1.5/HZ.
		 */
		if (unlikely(budget <= 0 ||
			     time_after_eq(jiffies, time_limit))) {
			/* Pairs with READ_ONCE() in softnet_seq_show() */
			WRITE_ONCE(sd->time_squeeze, sd->time_squeeze + 1);
			break;
		}
	}

	local_irq_disable();

	list_splice_tail_init(&sd->poll_list, &list);
	list_splice_tail(&repoll, &list);
	list_splice(&list, &sd->poll_list);
	if (!list_empty(&sd->poll_list))
		__raise_softirq_irqoff(NET_RX_SOFTIRQ);
	else
		sd->in_net_rx_action = false;

	net_rps_action_and_irq_enable(sd);
end:
	bpf_net_ctx_clear(bpf_net_ctx);
}
