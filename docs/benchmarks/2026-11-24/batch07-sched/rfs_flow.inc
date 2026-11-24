/* SPDX-License-Identifier: GPL-2.0 */
static struct rps_dev_flow *
set_rps_cpu(struct net_device *dev, struct sk_buff *skb,
	    struct rps_dev_flow *rflow, u16 next_cpu, u32 hash)
{
	if (next_cpu < nr_cpu_ids) {
		u32 head;
#ifdef CONFIG_RFS_ACCEL
		struct netdev_rx_queue *rxqueue;
		struct rps_dev_flow *flow_table;
		struct rps_dev_flow *old_rflow;
		struct rps_dev_flow *tmp_rflow;
		rps_tag_ptr q_tag_ptr;
		unsigned int tmp_cpu;
		u16 rxq_index;
		u32 flow_id;
		int rc;

		/* Should we steer this flow to a different hardware queue? */
		if (!skb_rx_queue_recorded(skb) || !dev->rx_cpu_rmap ||
		    !(dev->features & NETIF_F_NTUPLE))
			goto out;
		rxq_index = cpu_rmap_lookup_index(dev->rx_cpu_rmap, next_cpu);
		if (rxq_index == skb_get_rx_queue(skb))
			goto out;

		rxqueue = dev->_rx + rxq_index;
		q_tag_ptr = READ_ONCE(rxqueue->rps_flow_table);
		if (!q_tag_ptr)
			goto out;

		flow_id = rfs_slot(hash, q_tag_ptr);
		flow_table = rps_tag_to_table(q_tag_ptr);
		tmp_rflow = flow_table + flow_id;
		tmp_cpu = READ_ONCE(tmp_rflow->cpu);

		if (READ_ONCE(tmp_rflow->filter) != RPS_NO_FILTER) {
			if (rps_flow_is_active(tmp_rflow,
					       rps_tag_to_log(q_tag_ptr),
					       tmp_cpu)) {
				if (hash != READ_ONCE(tmp_rflow->hash) ||
				    next_cpu == tmp_cpu)
					goto out;
			}
		}

		rc = dev->netdev_ops->ndo_rx_flow_steer(dev, skb,
							rxq_index, flow_id);
		if (rc < 0)
			goto out;

		old_rflow = rflow;
		rflow = tmp_rflow;
		WRITE_ONCE(rflow->filter, rc);
		WRITE_ONCE(rflow->hash, hash);

		if (old_rflow->filter == rc)
			WRITE_ONCE(old_rflow->filter, RPS_NO_FILTER);
	out:
#endif
		head = READ_ONCE(per_cpu(softnet_data, next_cpu).input_queue_head);
		rps_input_queue_tail_save(&rflow->last_qtail, head);
	}

	WRITE_ONCE(rflow->cpu, next_cpu);
	return rflow;
}
static int get_rps_cpu(struct net_device *dev, struct sk_buff *skb,
		       struct rps_dev_flow **rflowp)
{
	struct netdev_rx_queue *rxqueue = dev->_rx;
	rps_tag_ptr global_tag_ptr, q_tag_ptr;
	struct rps_map *map;
	int cpu = -1;
	u32 tcpu;
	u32 hash;

	if (skb_rx_queue_recorded(skb)) {
		u16 index = skb_get_rx_queue(skb);

		if (unlikely(index >= dev->real_num_rx_queues)) {
			WARN_ONCE(dev->real_num_rx_queues > 1,
				  "%s received packet on queue %u, but number "
				  "of RX queues is %u\n",
				  dev->name, index, dev->real_num_rx_queues);
			goto done;
		}
		rxqueue += index;
	}

	/* Avoid computing hash if RFS/RPS is not active for this rxqueue */

	q_tag_ptr = READ_ONCE(rxqueue->rps_flow_table);
	map = rcu_dereference(rxqueue->rps_map);
	if (!q_tag_ptr && !map)
		goto done;

	skb_reset_network_header(skb);
	hash = skb_get_hash(skb);
	if (!hash)
		goto done;

	global_tag_ptr = READ_ONCE(net_hotdata.rps_sock_flow_table);
	if (q_tag_ptr && global_tag_ptr) {
		struct rps_sock_flow_table *sock_flow_table;
		struct rps_dev_flow *flow_table;
		struct rps_dev_flow *rflow;
		u32 next_cpu;
		u32 flow_id;
		u32 ident;

		/* First check into global flow table if there is a match.
		 * This READ_ONCE() pairs with WRITE_ONCE() from rps_record_sock_flow().
		 */
		flow_id = hash & rps_tag_to_mask(global_tag_ptr);
		sock_flow_table = rps_tag_to_table(global_tag_ptr);
		ident = READ_ONCE(sock_flow_table[flow_id].ent);
		if ((ident ^ hash) & ~net_hotdata.rps_cpu_mask)
			goto try_rps;

		next_cpu = ident & net_hotdata.rps_cpu_mask;

		/* OK, now we know there is a match,
		 * we can look at the local (per receive queue) flow table
		 */
		flow_id = rfs_slot(hash, q_tag_ptr);
		flow_table = rps_tag_to_table(q_tag_ptr);
		rflow = flow_table + flow_id;
		tcpu = rflow->cpu;

		/*
		 * If the desired CPU (where last recvmsg was done) is
		 * different from current CPU (one in the rx-queue flow
		 * table entry), switch if one of the following holds:
		 *   - Current CPU is unset (>= nr_cpu_ids).
		 *   - Current CPU is offline.
		 *   - The current CPU's queue tail has advanced beyond the
		 *     last packet that was enqueued using this table entry.
		 *     This guarantees that all previous packets for the flow
		 *     have been dequeued, thus preserving in order delivery.
		 */
		if (unlikely(tcpu != next_cpu) &&
		    (tcpu >= nr_cpu_ids || !cpu_online(tcpu) ||
		     ((int)(READ_ONCE(per_cpu(softnet_data, tcpu).input_queue_head) -
		      rflow->last_qtail)) >= 0)) {
			tcpu = next_cpu;
			rflow = set_rps_cpu(dev, skb, rflow, next_cpu, hash);
		}

		if (tcpu < nr_cpu_ids && cpu_online(tcpu)) {
			*rflowp = rflow;
			cpu = tcpu;
			goto done;
		}
	}

try_rps:

	if (map) {
		tcpu = map->cpus[reciprocal_scale(hash, map->len)];
		if (cpu_online(tcpu)) {
			cpu = tcpu;
			goto done;
		}
	}

done:
	return cpu;
}
