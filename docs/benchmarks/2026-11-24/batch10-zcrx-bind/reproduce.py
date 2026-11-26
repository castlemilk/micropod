"""Exercise the pinned lower-driver gates for netkit queue leasing and ZCRX binding."""
import argparse
import gzip
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1] / "2026-11-21/gamma-direct-macvlan.json.gz"
FILES = {
    "net/core/netdev_queues.c": "ef8c2a0f71198d86eb7154719f8d89efd697cbd4e8420fd43bba36466e59ee24",
    "net/core/netdev_rx_queue.c": "14e40b582998ef342ea48eba663daa41ba71cf627127d84d16b268920650023c",
    "net/core/dev.c": "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274",
    "net/core/netdev-genl.c": "51287e03a715b551e8ddac964c02e3548119d128b3299cd2383534b4329c54f0",
    "net/ethernet/eth.c": "3d5685a4a72156c9cc4a072ea11497227a8881471a8a5e2676e17b0b3e1faa19",
    "drivers/net/netkit.c": "cd7425f0d282bb02838491c474b6fe241a1966f4f9317bc4a043fa7772dd3f0e",
    "drivers/net/virtio_net.c": "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace",
    "io_uring/zcrx.c": "81710ffc59b47cacbcabc7f673d298ab7eff6de7e962b9663c88b8dda4f789c2",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def original(source, signature):
    start = source.index(signature.encode())
    return source[start:source.index(b"\n}\n", start) + 3]


def replay(kernel):
    files = {k: (kernel/k).read_bytes() for k in FILES}
    for member, blob in files.items():
        assert sha(blob) == FILES[member], member
    virt = files["drivers/net/virtio_net.c"]
    assert b"alloc_etherdev_mq(" in virt and b"SET_NETDEV_DEV(dev, &vdev->dev);" in virt
    assert b"queue_mgmt_ops" not in virt and b"ndo_queue_get_dma_dev" not in virt
    ether = files["net/ethernet/eth.c"]
    assert b"alloc_netdev_mqs(" in ether and b"ether_setup, txqs, rxqs" in ether
    assert b"queue_mgmt_ops" not in ether and b"dev = kvzalloc_flex(*dev" in files["net/core/dev.c"]
    netkit = files["drivers/net/netkit.c"]
    table = netkit.split(b"netkit_queue_mgmt_ops = {", 1)[1].split(b"};", 1)[0]
    assert table.strip().split() == [b".ndo_queue_create", b"=", b"netkit_queue_create,"]
    assert b"dev->queue_mgmt_ops = &netkit_queue_mgmt_ops;" in netkit
    genl = files["net/core/netdev-genl.c"]
    branch = genl.split(b"if (!netdev_can_lease_queue(dev_lease, info->extack))", 1)[1]
    assert b"err = -EINVAL;" in branch.split(b"}", 1)[0]
    zcrx = original(files["io_uring/zcrx.c"], "static int zcrx_register_netdev(")
    assert zcrx.index(b"netdev_queue_get_dma_dev(") < zcrx.index(b"netif_mp_open_rxq(")
    assert b"ret = -EOPNOTSUPP;" in zcrx.split(b"if (!ifq->dev) {")[1].split(b"}")[0]
    queues = files["net/core/netdev_queues.c"]
    receive = files["net/core/netdev_rx_queue.c"]
    assert b"return __netif_mp_open_rxq(dev, rxq_idx, p, extack);" in receive
    funcs = [original(queues, sig) for sig in (
        "static struct device *\n__netdev_queue_get_dma_dev(",
        "bool netdev_can_create_queue(", "bool netdev_can_lease_queue(")]
    funcs.append(original(receive, "static int netdev_rx_queue_reconfig("))
    funcs.append(original(receive, "static int __netif_mp_open_rxq("))
    config_archive = ARCHIVE.read_bytes()
    assert sha(config_archive) == "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
    kernel_cfg = json.loads(gzip.decompress(config_archive))["kernels"]["full"]
    config = kernel_cfg["config"].encode()
    assert sha(config) == kernel_cfg["config_sha256"]
    for line in (b"CONFIG_VIRTIO_NET=y", b"CONFIG_IO_URING_ZCRX=y", b"CONFIG_NETKIT=y",
                 b"# CONFIG_XDP_SOCKETS is not set"):
        assert line in config.splitlines()
    # Physical lower driver's queue-ops presence is the only change within each pair.
    arm_order = [(1, 0), (1, 1), (0, 1), (0, 0)]
    with tempfile.TemporaryDirectory() as work:
        p = Path(work)
        (p / "linux-admission.h").write_bytes(b"\n".join(funcs))
        exe = p / "bind"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", work,
                        str(HERE/"fixture.c"), "-o", str(exe)], check=True)
        lines = subprocess.check_output([str(exe)], text=True,
                    input="".join(f"{dma} {ops}\n" for dma, ops in arm_order)).splitlines()
    rows = []
    names = ("netkit_can_create", "lower_can_lease", "dma_available", "direct_inner_open_rc",
             "driver_allocation_callbacks", "callback_saw_provider", "provider_left_bound")
    assert len(lines) == 4
    for (dma, ops), line in zip(arm_order, lines):
        actual = list(map(int, line.split()))
        callback = dma * ops
        assert actual == [1, ops, dma, -11 if callback else -95, callback, callback, 0]
        rows.append(dict(lower_parent_has_dma_mask=bool(dma), lower_queue_ops_present=bool(ops),
                         outputs=dict(zip(names, actual))))
    return dict(date="2026-11-24", tier="source/fixture", direction="233.04",
                base="2e9b37c1e68334c443d71b729f0bd6334d824ddd", kernel="7.3.5",
                kernel_tar_sha256="8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
                kernel_file_sha256=FILES, config_sha256=sha(config),
                config_archive_sha256=sha(config_archive), compiled_sha256=sha(b"\n".join(funcs)),
                fixture_sha256=sha((HERE/"fixture.c").read_bytes()),
                reproducer_sha256=sha(Path(__file__).read_bytes()),
                cc=subprocess.check_output(["cc","--version"],text=True).splitlines()[0],
                fixed="present physical lower and valid queue 0; single unbound queue, "
                      "header split enabled, threshold zero, no XDP, default RX page size; "
                      "netkit peer modeled with its real create callback field present",
                callback="instrumented driver memory allocation always returns Linux -EAGAIN; "
                         "passing this point demonstrates actual driver callback dispatch only",
                rows=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("linux_source", type=Path)
    parser.add_argument("new_output", type=Path)
    args = parser.parse_args()
    result = replay(args.linux_source)
    with args.new_output.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
