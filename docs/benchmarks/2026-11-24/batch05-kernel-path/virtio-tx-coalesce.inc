// SPDX-License-Identifier: GPL-2.0-or-later
// Linux 7.3.5, drivers/net/virtio_net.c, Copyright 2007 Rusty Russell <rusty@rustcorp.com.au> IBM Corporation.
// Selected functions verbatim. See napi_tx.py for whole-file and source tar hashes.
// End provenance header.
static int virtnet_coal_params_supported(struct ethtool_coalesce *ec)
{
	/* usecs coalescing is supported only if VIRTIO_NET_F_NOTF_COAL
	 * or VIRTIO_NET_F_VQ_NOTF_COAL feature is negotiated.
	 */
	if (ec->rx_coalesce_usecs || ec->tx_coalesce_usecs)
		return -EOPNOTSUPP;

	if (ec->tx_max_coalesced_frames > 1 ||
	    ec->rx_max_coalesced_frames != 1)
		return -EINVAL;

	return 0;
}

static int virtnet_should_update_vq_weight(int dev_flags, int weight,
					   int vq_weight, bool *should_update)
{
	if (weight ^ vq_weight) {
		if (dev_flags & IFF_UP)
			return -EBUSY;
		*should_update = true;
	}

	return 0;
}

static int virtnet_set_per_queue_coalesce(struct net_device *dev,
					  u32 queue,
					  struct ethtool_coalesce *ec)
{
	struct virtnet_info *vi = netdev_priv(dev);
	int ret, napi_weight;
	bool update_napi = false;

	if (queue >= vi->max_queue_pairs)
		return -EINVAL;

	/* Can't change NAPI weight if the link is up */
	napi_weight = ec->tx_max_coalesced_frames ? NAPI_POLL_WEIGHT : 0;
	ret = virtnet_should_update_vq_weight(dev->flags, napi_weight,
					      vi->sq[queue].napi.weight,
					      &update_napi);
	if (ret)
		return ret;

	if (virtio_has_feature(vi->vdev, VIRTIO_NET_F_VQ_NOTF_COAL))
		ret = virtnet_send_notf_coal_vq_cmds(vi, ec, queue);
	else
		ret = virtnet_coal_params_supported(ec);

	if (ret)
		return ret;

	if (update_napi)
		vi->sq[queue].napi.weight = napi_weight;

	return 0;
}

static int virtnet_get_per_queue_coalesce(struct net_device *dev,
					  u32 queue,
					  struct ethtool_coalesce *ec)
{
	struct virtnet_info *vi = netdev_priv(dev);

	if (queue >= vi->max_queue_pairs)
		return -EINVAL;

	if (virtio_has_feature(vi->vdev, VIRTIO_NET_F_VQ_NOTF_COAL)) {
		mutex_lock(&vi->rq[queue].dim_lock);
		ec->rx_coalesce_usecs = vi->rq[queue].intr_coal.max_usecs;
		ec->tx_coalesce_usecs = vi->sq[queue].intr_coal.max_usecs;
		ec->tx_max_coalesced_frames = vi->sq[queue].intr_coal.max_packets;
		ec->rx_max_coalesced_frames = vi->rq[queue].intr_coal.max_packets;
		ec->use_adaptive_rx_coalesce = vi->rq[queue].dim_enabled;
		mutex_unlock(&vi->rq[queue].dim_lock);
	} else {
		ec->rx_max_coalesced_frames = 1;

		if (vi->sq[queue].napi.weight)
			ec->tx_max_coalesced_frames = 1;
	}

	return 0;
}
