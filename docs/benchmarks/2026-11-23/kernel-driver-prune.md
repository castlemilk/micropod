# Removing the Mellanox ConnectX driver from a virtio worker

The opt-in `full-no-mlx5` kernel profile disables `CONFIG_MLX5_CORE`. The stock 7.3.5 worker compiled 113 objects from this driver family. On the captured Gamma worker, the kernel bound `eth0` to `virtio_net`. These findings qualify a candidate for issue #235.02. Candidate Image size, boot performance and workload compatibility still need a native paired run. [Gamma NIC capture](../2026-11-21/gamma-vnic.json.gz)

## Stock footprint

The archived native GCC 15.2.0 build log recorded 87 distinct C compilation targets under `drivers/net/ethernet/mellanox/mlx5/` and 26 under `drivers/infiniband/hw/mlx5/`. The archived stock Image is 29,483,520 bytes, SHA-256 `7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd`.

I decoded all 54,432 entries in its kallsyms index using the layout in Linux 7.3.5 `scripts/kallsyms.c`. The token offsets, every 256th name marker, address ordering and the complete sorted-name permutation checked out. There are 2,057 distinct addresses where all names refer to text symbols beginning with `mlx5`. The distances from those addresses to the next distinct symbol total **577,096 bytes**. These spans include alignment padding and omit code or data with other names. Relinking changes layout. The net size reduction needs a candidate Image.

## Resolved configuration

I applied the builder’s configuration fragment to fresh copies of the pinned Apple seed and ran the pinned upstream `conf --olddefconfig Kconfig` for arm64. The control and candidate used the same Apple Clang 21.0.0 target probes and LLD 23.1.1. Independent candidate resolutions produced the same SHA-256. The archived native config was produced with Alpine GCC 15.2.0 and pahole 1.30. [Resolver and host toolchain details](research-kernel-capabilities.md)

| Config or input | SHA-256 |
| --- | --- |
| Linux 7.3.5 source archive | `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990` |
| Apple seed | `a5dfc1ee37dcd4bc6d727e4de617bc45a40cf32e7ebc52fb6f0472c8fbf60c21` |
| Archived native stock config | `a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c` |
| Locally resolved `full` | `a7aa0d0b33365fcd81abf1b88afa6901e030f94d98670772c5f7ce30f08cae77` |
| Locally resolved `full-no-mlx5` | `4a300c1dbd620730bb3c7599938d3135d9fffba3703532833764e7267bf082c5` |

The paired configurations differ in 13 entries. “Absent” means the resolver omitted the symbol from the output file.

| Full | Candidate | Symbols (CONFIG_ prefix) |
| --- | --- | --- |
| Built in | Disabled | MLX5_CORE |
| Built in | Absent | MLX5_CORE_EN, MLX5_EN_ARFS, MLX5_EN_RXNFC, MLX5_INFINIBAND, **NET_DEVLINK** |
| Disabled | Absent | MLX5_CORE_IPOIB, MLX5_DPLL, MLX5_ESWITCH, MLX5_FPGA, MLX5_MPFS, MLX5_SF, MLX5_VFIO_PCI |

The shared `NET_DEVLINK` management interface disappears because `MLX5_CORE` selects it and no remaining option selects it in this configuration. Validate any devlink consumers separately. A guest assigned a ConnectX device needs its driver. The Gamma capture only identifies the driver for its observed Ethernet interface.

All three configs retained built-in PCI, the tested virtio transports and devices (including storage, Ethernet, console, vsock and virtio-fs), ext4, OverlayFS, preemption, cgroups, namespaces, seccomp, SELinux, CPU mitigations, macvlan, nftables inet and core InfiniBand. The new profile checks eight device and filesystem settings immediately after configuration. A control with `VIRTIO_BLK` disabled failed at that guard. An existing destination failed preflight. The 16 KiB builder replay also passed its existing output-directory, interrupted publication and configuration checks.

## Native comparison

On an ARM64 Linux builder with the pinned toolchain, run the two profiles against the same Apple seed in separate output directories. The shared release string allows workload comparisons with an unchanged `uname -r`. Record Image hashes, byte sizes and build times before booting separate worker homes. Check boot, disk and overlay mounts, the published NIC, vsock, shared filesystem and workload operations. Capture devlink requirements and any hardware assignments alongside the results.

```sh
ci/build-worker-kernel.sh linux-7.3.5.tar.xz apple.config control full
ci/build-worker-kernel.sh linux-7.3.5.tar.xz apple.config candidate full-no-mlx5
```

The compressed receipt contains both full resolved configs, historical compilation targets, per-symbol spans, the stock decoder, source hashes, and configuration guard results. SHA-256 `08ef78a64badfef5bd28f9dbcb9f6e6c21e70f6a8e4d5980a93741ae6086d6c8`. [Machine-readable evidence](kernel-driver-prune.json.gz)
