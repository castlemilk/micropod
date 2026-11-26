"""Extract original timers and option cases from independently checked Linux v7.3.5 sources."""
import argparse
import hashlib
from pathlib import Path

FILES = {"tcp.h": "318474710a75e19f06deb9ce9b8af8fef4ed0fe3c7ba0d09837af2c4577a05c5",
         "tcp.c": "ddac70efc3730e0f6be6d63b8b08df3a028996403716d8298e097320ee9386df",
         "tcp_ipv4.c": "bbe547fe1e0a079d42c3c05ccf9f94f70fa70ac33a37d950882bf36890adfdcc",
         "tcp_output.c": "b55846bf35be5799cc19318c9215aa1b8a9a4881f8e3794cf5dc08b8aa4ea5b7"}


def code(source, start, end):
    i = source.index(start)
    j = source.index(end, i)
    return source[i:j + len(end)]


def extract(directory):
    blobs = {name: (directory / name).read_bytes() for name in FILES}
    assert {k:hashlib.sha256(b).hexdigest() for k,b in blobs.items()} == FILES
    h, tcp, ip, out = (blobs[k].decode() for k in FILES)
    pieces = ["/* SPDX-License-Identifier: GPL-2.0-or-later */",
              "/* Extracted from Linux v7.3.5. Regenerate with extract.py and the pinned whole files. */"]
    constants = ["TCP_RTO_MIN", "TCP_TIMEOUT_MIN", "TCP_TIMEOUT_MIN_US", "TCP_TIMEOUT_INIT"]
    for name in constants:
        pieces.append(next(line for line in h.splitlines() if line.startswith("#define "+name)
                           and line.split()[1] == name))
    pieces += ["static void configure_defaults(struct sock *sk) {",
               "struct net *net = sock_net(sk); struct inet_connection_sock *icsk = inet_csk(sk); int rto_min_us;",
               code(ip, "net->ipv4.sysctl_tcp_rto_min_us =", ";"),
               code(tcp, "rto_min_us = READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_rto_min_us);", "icsk->icsk_rto_min = usecs_to_jiffies(rto_min_us);"), "}",
               "static int set_option(struct sock *sk, int val) { switch (TCP_RTO_MIN_US) {",
               code(tcp, "case TCP_RTO_MIN_US: {", "\n\t}"), "} return -EINVAL; }",
               "static int get_option(struct sock *sk) { int val; switch (TCP_RTO_MIN_US) {",
               code(tcp, "case TCP_RTO_MIN_US:\n", "break;"), "} return val; }",
               code(h, "static inline u32 tcp_rto_min(const", "\n}"),
               code(h, "static inline u32 tcp_rto_min_us(const", "\n}"),
               code(out,"bool tcp_schedule_loss_probe(struct sock", "\n}")]
    return "\n".join(pieces)+"\n"


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("source_dir",type=Path)
    p.add_argument("output",type=Path)
    a=p.parse_args()
    with a.output.open("x") as f:
        f.write(extract(a.source_dir))
