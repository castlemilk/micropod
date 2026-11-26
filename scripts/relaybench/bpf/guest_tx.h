/* SPDX-License-Identifier: GPL-2.0 */
#ifndef MICROPOD_GUEST_TX_H
#define MICROPOD_GUEST_TX_H

struct tx_config {
    unsigned long long start_ns;
    unsigned long long end_ns;
    unsigned int netns_inum;
    unsigned int ifindex;
    unsigned int queue;
    unsigned int service_tgid;
    unsigned int service_netns;
    unsigned int service_port;
    unsigned int service_pad;
};

struct tx_counts {
    unsigned long long attempts;
    unsigned long long attempted_bytes;
    unsigned long long completed_calls;
    unsigned long long tx_ok;
    unsigned long long tx_busy;
    unsigned long long tx_other;
    unsigned long long dql_charged_bytes;
    unsigned long long read_errors;
    unsigned long long overlaps;
    unsigned long long boundary_crossings;
};

#endif
