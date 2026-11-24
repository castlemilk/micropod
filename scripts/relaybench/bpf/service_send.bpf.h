/* SPDX-License-Identifier: GPL-2.0 */
// Optional return-side TCP accounting. The queue observer supplies config,
// struct net and the common monotonic window. CO-RE resolves the socket fields.
struct sock_common {
    unsigned short skc_num;
    struct { struct net *net; } skc_net;
};
struct sock { struct sock_common __sk_common; };

struct service_totals {
    __u64 calls;
    __u64 requested_bytes;
    __u64 accepted_bytes;
    __u64 full_calls;
    __u64 short_calls;
    __u64 zero_calls;
    __u64 error_calls;
    __u64 read_errors;
    __u64 oversized_returns;
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct service_totals);
} service_counts SEC(".maps");

// Linux 7.3.5: int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size).
// The fexit trampoline supplies three argument slots followed by its int result.
SEC("fexit/tcp_sendmsg")
int service_send(__u64 *ctx)
{
    const __u32 key = 0;
    const struct tx_config *cfg = bpf_map_lookup_elem(&config, &key);
    if (!cfg || !cfg->service_tgid || (bpf_get_current_pid_tgid() >> 32) != cfg->service_tgid)
        return 0;
    const __u64 now = bpf_ktime_get_ns();
    if (now < cfg->start_ns || now >= cfg->end_ns)
        return 0;

    struct service_totals *total = bpf_map_lookup_elem(&service_counts, &key);
    if (!total)
        return 0;
    struct sock *sk = (void *)ctx[0];
    __u16 port;
    if (bpf_core_read(&port, sizeof(port), &sk->__sk_common.skc_num))
        goto read_error;
    if (port != cfg->service_port)
        return 0;
    struct net *net;
    __u32 ns;
    if (bpf_core_read(&net, sizeof(net), &sk->__sk_common.skc_net.net) ||
        bpf_core_read(&ns, sizeof(ns), &net->ns.inum))
        goto read_error;
    if (ns != cfg->service_netns)
        return 0;

    const __u64 requested = ctx[2];
    const int ret = (int)ctx[3];
    total->calls++;
    total->requested_bytes += requested;
    if (ret < 0) {
        total->error_calls++;
    } else if (!ret) {
        total->zero_calls++;
    } else if ((__u64)ret > requested) {
        total->oversized_returns++;
    } else {
        total->accepted_bytes += (__u64)ret;
        if ((__u64)ret < requested)
            total->short_calls++;
        else
            total->full_calls++;
    }
    return 0;

read_error:
    total->read_errors++;
    return 0;
}
