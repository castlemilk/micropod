"""Extract a compact Linux 7.3.5 fixture from verified upstream source blobs."""
import argparse
import hashlib
from pathlib import Path

PINS = {
    "net/core/dev.c": "f803d8ba866ffb7c20e0e133ed588dd62775c8dd",
    "net/core/sysctl_net_core.c": "eb35da3556f4aa00cecd4582ab94e339d2518506",
    "net/core/hotdata.c": "b0f51a726a3d2dd518b97354dc5e0127d1b7f4e8",
    "include/linux/jiffies.h": "bbd57061802cd090ee65a1458cda4dbf82058c90",
    "kernel/sysctl.c": "38597f26b34c37ac91bcb1a160c2ee6edaa11ce3",
}


def cut(text, start, end):
    first = text.index(start)
    last = text.index(end, first)
    return text[first:last + len(end)]


def extract(directory):
    sources = {}
    for name, pin in PINS.items():
        original = directory / name
        data = (original if original.is_file() else directory / Path(name).name).read_bytes()
        if hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest() != pin:
            raise ValueError(f"upstream git blob changed: {name}")
        sources[Path(name).name] = data.decode()
    dev = sources["dev.c"]
    core = sources["sysctl_net_core.c"]
    hot = sources["hotdata.c"]
    jiffies = sources["jiffies.h"]
    sysctl = sources["sysctl.c"]
    if "do_proc_int_conv_minmax" not in cut(sysctl, "int proc_dointvec_minmax(const", "\n}"):
        raise ValueError("sysctl conversion handler changed")
    lines = [
        "/* SPDX-License-Identifier: GPL-2.0 */",
        "/* Generated Linux 7.3.5 portions. See extract.py for paths and original blob IDs. */",
        cut(core, "static int netdev_budget_usecs_min =", ";"),
        "static struct { int netdev_budget, netdev_budget_usecs; } net_hotdata = {",
    ]
    for name in ("netdev_budget", "netdev_budget_usecs"):
        lines.append(next(line for line in hot.splitlines() if line.strip().startswith("." + name + " =")))
    lines += [
        "};", "static const struct ctl_table entry = {",
        cut(core, '.procname\t= "netdev_budget_usecs"', ".extra1\t\t= &netdev_budget_usecs_min,"), "};",
    ]
    for signature in ("int proc_int_k2u_conv_kop(", "int proc_int_u2k_conv_uop(", "int proc_int_conv(",
                      "static int sysctl_user_to_kern_int_conv(", "static int sysctl_kern_to_user_int_conv(",
                      "static int do_proc_int_conv_minmax("):
        lines.append(cut(sysctl, signature, "\n}"))
    conditional = cut(jiffies[jiffies.index("extern unsigned long __usecs_to_jiffies"):], "#if !(USEC_PER_SEC % HZ)", "#else")
    lines.append(cut(conditional, "static inline unsigned long _usecs_to_jiffies(", "\n}"))
    lines.append(cut(dev, "static __latent_entropy void net_rx_action(void)", "\n}"))
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("new_output", type=Path)
    args = parser.parse_args()
    with args.new_output.open("x") as out:
        out.write(extract(args.source_dir))
