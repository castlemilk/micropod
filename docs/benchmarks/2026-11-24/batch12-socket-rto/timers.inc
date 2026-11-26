/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Extracted from Linux v7.3.5. Regenerate with extract.py and the pinned whole files. */
#define TCP_RTO_MIN	((unsigned)(HZ / 5))
#define TCP_TIMEOUT_MIN	(2U) /* Min timeout for TCP timers in jiffies */
#define TCP_TIMEOUT_MIN_US (2*USEC_PER_MSEC) /* Min TCP timeout in microsecs */
#define TCP_TIMEOUT_INIT ((unsigned)(1*HZ))	/* RFC6298 2.1 initial RTO value	*/
static void configure_defaults(struct sock *sk) {
struct net *net = sock_net(sk); struct inet_connection_sock *icsk = inet_csk(sk); int rto_min_us;
net->ipv4.sysctl_tcp_rto_min_us = jiffies_to_usecs(TCP_RTO_MIN);
rto_min_us = READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_rto_min_us);
	icsk->icsk_rto_min = usecs_to_jiffies(rto_min_us);
}
static int set_option(struct sock *sk, int val) { switch (TCP_RTO_MIN_US) {
case TCP_RTO_MIN_US: {
		int rto_min = usecs_to_jiffies(val);

		if (rto_min > TCP_RTO_MIN || rto_min < TCP_TIMEOUT_MIN)
			return -EINVAL;
		WRITE_ONCE(inet_csk(sk)->icsk_rto_min, rto_min);
		return 0;
	}
} return -EINVAL; }
static int get_option(struct sock *sk) { int val; switch (TCP_RTO_MIN_US) {
case TCP_RTO_MIN_US:
		val = jiffies_to_usecs(READ_ONCE(inet_csk(sk)->icsk_rto_min));
		break;
} return val; }
static inline u32 tcp_rto_min(const struct sock *sk)
{
	const struct dst_entry *dst = __sk_dst_get(sk);
	u32 rto_min = READ_ONCE(inet_csk(sk)->icsk_rto_min);

	if (dst && dst_metric_locked(dst, RTAX_RTO_MIN))
		rto_min = dst_metric_rtt(dst, RTAX_RTO_MIN);
	return rto_min;
}
static inline u32 tcp_rto_min_us(const struct sock *sk)
{
	return jiffies_to_usecs(tcp_rto_min(sk));
}
bool tcp_schedule_loss_probe(struct sock *sk, bool advancing_rto)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
	struct tcp_sock *tp = tcp_sk(sk);
	u32 timeout, timeout_us, rto_delta_us;
	int early_retrans;

	/* Don't do any loss probe on a Fast Open connection before 3WHS
	 * finishes.
	 */
	if (rcu_access_pointer(tp->fastopen_rsk))
		return false;

	early_retrans = READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_early_retrans);
	/* Schedule a loss probe in 2*RTT for SACK capable connections
	 * not in loss recovery, that are either limited by cwnd or application.
	 */
	if ((early_retrans != 3 && early_retrans != 4) ||
	    !tcp_is_sack(tp) ||
	    (icsk->icsk_ca_state != TCP_CA_Open &&
	     icsk->icsk_ca_state != TCP_CA_CWR))
		return false;

	/* Probe timeout is 2*rtt. Add minimum RTO to account
	 * for delayed ack when there's one outstanding packet. If no RTT
	 * sample is available then probe after TCP_TIMEOUT_INIT.
	 */
	if (tp->srtt_us) {
		timeout_us = tp->srtt_us >> 2;
		if (tp->packets_out == 1)
			timeout_us += tcp_rto_min_us(sk);
		else
			timeout_us += TCP_TIMEOUT_MIN_US;
		timeout = usecs_to_jiffies(timeout_us);
	} else {
		timeout = TCP_TIMEOUT_INIT;
	}

	/* If the RTO formula yields an earlier time, then use that time. */
	rto_delta_us = advancing_rto ?
			jiffies_to_usecs(inet_csk(sk)->icsk_rto) :
			tcp_rto_delta_us(sk);  /* How far in future is RTO? */
	if (rto_delta_us > 0)
		timeout = min_t(u32, timeout, usecs_to_jiffies(rto_delta_us));

	tcp_reset_xmit_timer(sk, ICSK_TIME_LOSS_PROBE, timeout, true);
	return true;
}
