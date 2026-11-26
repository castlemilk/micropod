# OrbStack 2.2.5: how it is built and where the speed comes from

A map of the mechanisms behind OrbStack's container and VM performance,
read from the installed build rather than from its documentation. It
complements the [OrbStack scorecard](../bench/phase0-host-scheduling/docs/benchmarks/2026-11-23/orbstack-scorecard.md)
and the [optimization register](../bench/phase0-host-scheduling/docs/research/2026-11-23-optimization-register.md):
those record what OrbStack does faster, this records how it is built.
Section 11 lines the mechanisms up against the scorecard's "What remains to
win".

Target: OrbStack 2.2.5 (21124), `dev.kdrag0n.MacVirt`, VM host binary
`OrbStack Helper` sha256 `9898a51367c3…`, UUID `F05617E0-57D8-3E1C-951C-EB158B6406F3`.
Machine: Gamma (M5 Max, 18 cores, 128 GB, macOS 26.5.1), OrbStack configured
with the defaults `cpu: 4`, `memory_mib: 4096`, `setup.use_admin: false`.
Collected 25 November 2026.

## Method and evidence grades

Every claim carries a grade:

| Grade | Meaning | Sources |
|---|---|---|
| B | read from the shipped binaries | REA `inspect-macho`, `inspect-signature`, `inspect-plist`, `inspect-artifact`, `project-apple-application-graph`, `trace-dylib-resolution`; `strings` |
| R | read from the running OrbStack | `ps`, `sample`, `vmmap`, `lsof`, `ifconfig`, `~/.orbstack/log/vmgr.log` |
| G | read inside the guest kernel | four short-lived unprivileged `alpine:3.23` containers (`--rm`, all capabilities dropped) |
| K | read from the shipped kernel image | embedded `.config`, version string |
| D | vendor statement | docs.orbstack.dev, an HN comment by the author (June 2026) |

What was not done: no decompiler-level pass. REA's only configured deep
provider is Hopper `6.6.0-demo`, which accepted REA's bridge socket but never
answered its control protocol, so `search-strings`, `trace-feature` and
`function` could not run. Section 12 lists what that pass would settle.
The guest probes were unprivileged, so the VM's own mount table, `dmesg` and
root filesystem layout were not visible.

## 1. The short version

- One VM hosts everything. A custom VMM written in Rust drives
  Hypervisor.framework directly and presents a bare `virt`-style machine:
  virtio-mmio devices, a GICv3 and a PL011, with no PCIe. [B][G]
- `vmgr` is the only VM-owning process. It also serves the Docker socket,
  NFS, DNS, port forwards and the gVisor-based host network stack. [B][R]
- Boot is direct-to-kernel with a read-only EROFS root. The guest's init
  reports `Total boot time: 231ms`; the host had NFS mounted about two
  seconds after `vmgr` launched. [K][G][R]
- Memory is returned to macOS by free-page reporting on a custom
  virtio-balloon, backed by a zram swap device that outranks a 1 GiB disk
  swap file. [G][B]
- The writable disk is one huge sparse raw image holding a single Btrfs
  volume mounted `nodatacow,nodatasum,ssd,discard`; the host maps a 32 GiB
  window of it read-only. [R][G]
- Every virtio-net device negotiates TSO in both directions plus checksum
  offload, on single-queue devices. [G]
- The kernel is a 394-commit OrbStack patch series. Its guest reports
  `meltdown: Not affected`, consistent with the vendor's "no KPTI" claim,
  and the command line forces `id_aa64mmfr0.ecv=1`. [K][G][D]
- vCPU threads run at the default priority (31). Six I/O worker threads run
  *below* default (20). OrbStack does not buy throughput with thread
  priority. [R]
- Docker is a standard engine (29.8.2) using the containerd snapshotter on
  cgroup v2, with OrbStack's own userland-proxy stub. [G]

## 2. Process and privilege map

| Component | Size | Language (evidence) | Role |
|---|---|---|---|
| `Contents/MacOS/OrbStack` | 35.3 MB | Swift/SwiftUI, SwiftNIO, gRPC client | GUI; links Virtualization.framework but imports one symbol from it |
| `Frameworks/OrbStack Helper.app` (`vmgr`) | 73.2 MB | Rust VMM + Go (`__gopclntab` 23.6 MB) + Swift/XPC | The VM host and all host-side services |
| `MacOS/scli.app` (`orb`, `orbctl`) | 14.8 MB | Go + Swift | CLI |
| `Library/LaunchServices/dev.orbstack.OrbStack.privhelper` | 1.4 MB | Swift | `SMJobBless` privileged helper; no extra entitlements of its own |
| `MacOS/pstramp` | 53 KB | C, 516 bytes of code | `posix_spawn` with `responsibility_spawnattrs_setdisclaim` and a controlling-tty `ioctl` |

All from REA `inspect-macho`. The main app is sandboxed (app-group
container, hardened runtime) and holds `com.apple.security.virtualization`.
`vmgr` (`dev.kdrag0n.MacVirt.vmgr`) additionally holds
`com.apple.security.hypervisor` and `com.apple.vm.networking`. [B] No
component holds a Network Extension entitlement, and no network extension or
kernel extension is involved; `setup.use_admin` is `false` here. [B][R]

At runtime there are two processes: the GUI and
`OrbStack Helper vmgr -build-id macho:f05617e0… -handoff`, parented by
launchd. The build-id argument equals the binary's UUID. [R] `vmgr` serves
`~/.orbstack/run/docker.sock` directly and listens on `127.0.0.1:32222`
(SSH) and a loopback port for NFS. [R]

## 3. The VM

### Two backends behind one interface

| Linkage of `vmgr` | Symbols | Meaning |
|---|---|---|
| `Hypervisor.framework` | 21: `hv_vm_create`, `hv_vm_map/protect/unmap`, `hv_vm_config_set_ipa_size`, `hv_vcpu_run`, `hv_vcpu_get/set_vtimer_mask`, … | the VMM is written against the hypervisor interface itself |
| `vmnet.framework` | 17: `vmnet_start_interface`, `vmnet_read/write`, keys for TSO, checksum offload, MTU, max packet size | vmnet is driven directly, not through `VZVirtualMachine` |
| `Virtualization.framework` | 4 Swift methods: `VZVirtualMachine.start/pause/resume`, `VZVirtioSocketDevice.connect` | a second backend, `swext.vzfMachine`, exists in the binary |

Go symbols show a `vmm.Machine` interface with two implementations:
`rsvm` (cgo calls named `rsvm_machine_start`, `rsvm_new_machine`, …) and
`swext.vzfMachine`. The author's description, "instead of
Virtualization.framework, we have a custom Rust virtualization stack"
[D], matches the Rust backend that is running. Which conditions select the
Virtualization.framework backend was not determined. [B]

### Platform and devices

Guest devices sit on virtio-mmio at `0x4000xxxx`. The binary builds a device
tree at run time (property names `next-level-cache`, `cache-level`,
`cache-size`, `cache-line-size`, `arm,psci-0.2` are all present), and Go code
contains `configureCPUCacheTopology`, `syntheticL3CacheLevel` and
`cpusPerGuestCacheTopology`, so the guest is given a synthetic cache
topology. [B][G]

| MMIO address | Device | Negotiated device features (bit numbers from guest sysfs) |
|---|---|---|
| `0x40003000` | virtio-balloon | 1 STATS_VQ, 3 SIZES, 5 REPORTING |
| `0x40004000` | virtio-rng | — |
| `0x40005000` | virtio-console | SIZE, MULTIPORT; ports 0, `orb-stdin`, `orb-stdout` |
| `0x40006000` | virtio-snd | — |
| `0x40007000`, `0x40008000` | virtiofs ×2 | — |
| `0x40009000` | virtio-blk `vda` (root) | RO, FLUSH, MQ, DISCARD, WRITE_ZEROES |
| `0x4000a000` | virtio-blk `vdb` (data) | FLUSH, MQ, DISCARD, WRITE_ZEROES |
| `0x4000b000` | virtio-blk `vdc` (swap) | FLUSH, MQ, DISCARD, WRITE_ZEROES |
| `0x4001c000`, `0x4001d000`, `0x4001e000` | virtio-net ×3 | CSUM, GUEST_CSUM, MTU, MAC, GUEST_TSO4, GUEST_TSO6, HOST_TSO4, HOST_TSO6 |

All devices negotiate VERSION_1 and RING_RESET. No virtio-net device
negotiates MQ, MRG_RXBUF, STATUS or CTRL_VQ: they are single-queue devices
with segmentation offload. [G] OrbStack has two vmnet ports on the host:
`vmenet0` on `bridge100` (MTU 1500, carrying `network.subnet4:
192.168.138.0/23`), and `vmenet1` on `bridge101`. While a container runs,
`bridge101` is re-addressed to the active Docker subnet, here
`192.168.215.0/24`, which gives the Mac a direct route to container IPs. The
third virtio-net device never appears as a vmnet port: it is the
host-internal link that the published-port path uses (section 15). [R]

### Rust workspace

Source paths embedded in the binary name the VMM crates:

- `hvf` (Hypervisor.framework bindings, `aarch64/vcpu.rs`, `aarch64/vm.rs`,
  a built-in `profiler/` with DWARF symbolication and a Firefox-profiler
  exporter)
- `gicv3` (interrupt controller emulation)
- `vmm` (`builder.rs`, `macos/vstate.rs`, `resources.rs`)
- `devices`: `virtio/{balloon,block,console,fs,net,rng,snd,vsock}`,
  `usb/xhci`, `legacy/{aarch64/serial,rtc_pl031,gic}`
- `brnet` (bridge network), `gruel` (signal multiplexing), `libvirtue` (the
  library facade), `kernel` (command-line builder)

File sharing is a custom device: `virtio/fs/{server,worker,device,fuse,attrlist,rosetta}.rs`,
with FUSE and macOS `getattrlist` handling in Rust. The `vsock` crate is a
multiplexer for TCP, UDP and UNIX streams (`vsock/{tcp,udp,unix,muxer}.rs`),
not the standard virtio-vsock device; none appears in the guest's device
list. [B] Crates include tokio 1.45.1, axum 0.8.4, cpal 0.15.3 (an audio library) and
objc2-io-usb-host 0.3.2. [B]

### Host threads

Read with `ps -M` and `sample` in `vmgr`, 18.5 hours after launch: [R]

| Threads | Priority | CPU time |
|---|---|---|
| `vcpu0`–`vcpu3` | 31 (default) | 226, 204, 202, 201 min user; 10.1, 5.6, 5.5, 5.5 min system |
| `fs0 node trim` | 4 | idle |
| six threads among the virtio-fs, block and console workers and the `VMM main loop` | 20 | mostly idle; one has 10 min system |
| one thread, by position `xhci-irq` | 19 | idle |
| one thread, by position the CoreAudio `caulk.messenger.shared:high` | 55 | idle |
| three `net worker`, one `vmnet writer` | 31 | by position: one net worker has 49 min user; the vmnet writer 3.1 min user and 6.1 min system |
| `virtio-snd worker`, `audio control`, `com.apple.virtualization.thread.virtual-clock` | 31 | idle |

Thread names come from `sample`, which listed two more threads than `ps -M`
did at the same moment, so every name-to-priority pairing except the vCPUs
is positional. The four heavy threads are the vCPUs: the guest's per-CPU
busy figures (23.4%, 19.5%, 19.2%, 19.1%) track their host CPU time. About
97% of vCPU-thread time is accounted as user time, meaning few exits into
the host kernel.

`vmgr`'s physical footprint was 3.2 GB (peak 7.0 GB) for a 4 GiB VM.

## 4. Boot

The app ships only `kernel` (32.7 MB) and `rootfs.img` (430 MB, EROFS). There
is no bootloader and no x86 guest. `kernel.csmap` is a length-prefixed
table of kernel symbol names, passed to the VM as `kernelCsmap`; what
consumes it was not determined. [K][B] The kernel command line, read from
the guest:

```
init=/opt/orb/vinit workqueue.power_efficient=1 cgroup.memory=nokmem,nosocket
swiotlb=noforce slab_min_order=2 cgroup_v1_proc=1 nbd.nbds_max=4 can.stats_timer=0
arm64.nosme id_aa64mmfr0.ecv=1 root=/dev/vda rootfstype=erofs ro console=hvc0 quiet
ORB_S=<62-byte blob> earlycon=pl011,mmio32,0x40001000
```

(line breaks added). Points of interest: [G]

- `rootfstype=erofs ro`: the root filesystem is read-only, so it is never
  repaired, journaled or written, and the host can serve it from the page
  cache of a file mapped read-only. [R]
- `init=/opt/orb/vinit`: a purpose-built init, not systemd.
- `workqueue.power_efficient=1`: all kernel workqueues are power-efficient.
- `cgroup.memory=nokmem,nosocket`: no kernel-memory or socket-memory
  accounting in cgroups.
- `id_aa64mmfr0.ecv=1`: the guest is made to see FEAT_ECV (counter
  virtualisation); `vmgr` contains `supportsECV` and a
  `hw.optional.arm.FEAT_ECV` check.
- `ORB_S=`: a binary struct that contains the macOS build (`25F80`) and the
  device path `/dev/vport2p2`, the console port named `orb-stdout` that the
  guest reports on.

The guest log records the init's own timeline: `Booting OrbStack (+0ms)`,
`Network (+15ms)`, `Apply system settings`, `Late tasks: Emulation, Memory`
(`Using Rosetta`), `Data`, `Data volume ready`, `Initialize data (+212ms)`,
`Start services`, `Done`, `Total boot time: 231ms`. [R] That figure starts
at init and excludes kernel boot. On the host, the phases
`verify_rosetta → migrate_state → initialize_data_image → lock_data_image →
create_swap_image → parse_network_config → create_vm → start_net_services →
start_vm → start_host_services → notify_gui_ready` all completed within
17:41:14, and `NFS mounted` was logged at 17:41:16. [R]

## 5. Kernel and sysctls

`Linux version 7.2.12-orbstack-00394-gbecdd6130068`, built 22 October 2026
with ClangBuiltLinux clang/LLD 22.1.3, `#1 SMP PREEMPT`. The suffix denotes a
394-commit OrbStack patch series. [K]

OrbStack code is present in the kernel: the guest has a `/dev/krpc` misc
device backed by `krpc_init`, `krpc_dev_ioctl`, `krpc_file1_ioctl` and
`krpc_kthread`, plus an `orb_rvk_set_key` symbol. `vmgr` logs
`service is ready: service=krpc` at startup. The protocol carried by that
device was not determined. [G][R]

The embedded config is a 455-line list (405 `=y`, 50 `=m`) with no
"is not set" lines, so absence from it is not evidence that an option is
off. Built in: `BTRFS_FS`, `VIRTIO_FS`, `OVERLAY_FS`, `VIRTIO_NET`, `NETKIT`,
`VHOST_NET`, `BPF_LSM`; modules: `EXT4_FS`, `NFS_FS`, `XFS_FS`, `F2FS_FS`.
[K]

Mitigation state reported by the guest: `meltdown: Not affected`,
`spectre_v2: Mitigation: CSV2, but not BHB`, `spec_store_bypass: Vulnerable`.
The guest also sees a synthetic CPU identity (implementer `0x61`, part
`0x000`). OrbStack's documentation says KASLR protection is "augmented by a
security feature that doesn't incur the overhead of KPTI mitigations".
[D] The command line does not disable KPTI, so the `Not affected` result
most likely comes from the patch series; what replaces KPTI was not found.

Settings applied by "Apply system settings", all read in the guest: [G]

| Area | Value | Stock default |
|---|---|---|
| `vm.swappiness` | 20 | 60 |
| `vm.overcommit_memory` | 1 (always) | 0 |
| `vm.page-cluster` | 1 | 3 |
| `vm.compaction_proactiveness` | 0 | 20 |
| `vm.watermark_boost_factor` | 0 | 15000 |
| `kernel.sched_rt_runtime_us` | 1000000, equal to the period | 950000 |
| `net.core.rmem_max`, `wmem_max` | 7,500,000 | 212992 |
| `net.ipv4.tcp_rmem` max | 32,109,184 | 6291456 |
| `net.ipv4.tcp_challenge_ack_limit` | 2147483647 | 1000 |
| `net.netfilter.nf_conntrack_max` | 327680 | 262144 |
| `fs.file-max` | 9223372036854775807 | derived from memory |
| `fs.mount-max` | 100000 | 100000 |
| `kernel.threads-max` | 32138 | derived |
| `kernel.pid_max` | 4194304 | 32768 |
| `kernel.panic_on_oops` | 1, `kernel.panic` 10 | 0, 0 |

Defaults are from memory of mainline, not checked against 7.2.

## 6. Memory

- **Balloon with free-page reporting.** The guest's balloon negotiates
  REPORTING (bit 5) and SIZES (bit 3). The Rust balloon is
  `virtio/balloon/device.rs`, and `vmgr` imports `madvise`, `mincore` and
  `mach_vm_remap`. [G][B]
- **zram first.** `/dev/zram0` is a 4.18 GB disk with `comp_algorithm=[lz4]`
  used as swap at priority 32767. `/dev/vdc`, the 1 GiB `swap.img`, is swap
  at priority 1. In the guest, 5.1 GB of swap was almost entirely unused.
  On the host `swap.img` occupied 4 KB. [G][R]
- **Guest RAM is not file-backed.** `vmmap` shows about 4 GiB of 4 MiB
  regions (`SM=SHM`, memory tag 250) plus a 2 GiB reserved region; the
  attribution to guest RAM is inferred from size and placement. [R]

## 7. Storage

| Layer | What OrbStack does | Grade |
|---|---|---|
| Root | EROFS, read-only, 430 MB; mapped read-only in `vmgr` | K, R |
| Data | `data.img.raw`, a GPT disk image 1,995,166,464,656 bytes (about 1.8 TiB) but 12 GB allocated; one partition | R |
| Filesystem | Btrfs `user-data-fs`, subvolume `/docker`, mounted `rw,nodatasum,nodatacow,ssd,discard,space_cache=v2` | R, G |
| Btrfs features | `block_group_tree`, `free_space_tree`, `no_holes`, `skinny_metadata`, `simple_quota`, `verity`, `extended_iref`; nodesize 16 KiB | G |
| Block queue | scheduler `none`, read-ahead 8192 KB, DISCARD and WRITE_ZEROES negotiated | G |
| Host access | a 32 GiB window of `data.img.raw` is mapped `r--` shared (`SM=ALI`, 1.2 GB resident), so guest reads are served from the page cache without a copy | R |
| Container layers | Docker `Storage Driver: overlayfs`, `driver-type: io.containerd.snapshotter.v1` | G |

`nodatacow` removes copy-on-write from file data, which suits database and
container-layer workloads. `discard` pushes deletions to the host as hole
punching, which is why the image "automatically shrinks". `vmconfig`
contains `validateAPFS`, and `vmgr` imports `clonefile` and `fclonefileat`,
so the data location is required to be APFS. [B]

Host disks reach the guest as NBD or loop devices (`nbd.nbds_max=4`, four
`loop` devices, `vmgr/hostdisks`, `vmgr/vnet/services/disksrv`). [G][B]

## 8. File sharing

**Mac to guest.** Two custom virtiofs devices; a Mac path bind-mounted into a
container appears as `virtiofs mac rw`. `vmgr` runs `worker` and `node trim`
threads for each instance, and a `poller` for `fs0`; by its name, `node
trim` is cache eviction. Rust sources include `fs/attrlist.rs`, and `vmgr`
imports `getattrlistbulk` and `FSEventStreamCreate`. Go has `FsVmNotifier.UpdatePaths`
and a callback named `swext_fsevents_cb_krpc_events`: Mac file-change events
are forwarded into the guest over `krpc`. The guest has `autofs` and
`fuse` available. [G][R][B] The mount options and cache policy of the
virtiofs mounts could not be read from an unprivileged container.

**Guest to Mac.** NFS. `~/OrbStack` is `OrbStack:/OrbStack` mounted
`nfs,nodev,nosuid,noatime`. The guest starts `nfsd` on a passed-in file
descriptor (`/proc/self/fd/nfsd`), `vmgr` listens on a loopback port for the
Mac NFS client, and `vmgr` imports `mount`. [R][B]

**Rosetta.** `/Library/Apple/usr/libexec/oah/RosettaLinux` is shared into
the guest over virtiofs (`fs/rosetta.rs`), verified by the first startup
phase, `verify_rosetta`. [B][R]

## 9. Networking

- **vmnet with offload.** `vmgr` holds `com.apple.vm.networking` and uses
  the vmnet keys for TSO and checksum offload. Every guest NIC negotiates
  TSO4/TSO6 both ways and checksum offload. [B][G] The host-side port runs at
  MTU 1500. On the host, `vmenet0` reports `hwassist=<MULTIPAGES,TSO_V4,TSO_V6>`
  and `bridge100` has `RXCSUM,TXCSUM,TSO4,TSO6`. [R]
- **Host stack on gVisor.** Go packages under `vmgr/vnet` include
  `gvisorLogger.Emit` and link endpoints implementing gVisor's
  `LinkEndpoint` methods (`MTU`, `Capabilities`, `GSOMaxSize`,
  `SupportedGSO`, `WritePackets`). `dglink` dispatches packets with
  `recvmmsg` and `readv` batches; `cblink` marshals `virtioNetHdrV1`.
  Packets are handed to Rust through `rsvm_network_write_packet`. [B]
- **A service network at `0.250.250.0/24`.** The range is a literal in the
  binary and appears in the Docker engine's no-proxy list. Containers use
  `nameserver 0.250.250.200`. Forwarder errors name `0.250.250.2` as the
  host side. [B][G][R]
- **Forwards are code, not iptables.** `vmgr/vnet/tcpfwd` has
  `TcpHostForward`, `StreamVsockHostForward`, `UnixTcpHostForward`,
  `UnixNATForward` and `HostNFSForward`; `udpfwd` and `icmpfwd` handle UDP
  and ping. Pumps are specialised per endpoint pair (`Pump2SpTcpTcp`,
  `Pump2SpTcpUnix`, `Pump2SpUnixUnix`) with power-of-two buffers. [B]
- **Docker's port proxy is replaced.** `docker info` reports
  `UserlandProxyPath: /opt/orbstack-guest/pstub`. [G]
- **Proxy and DNS follow macOS.** The engine is configured with
  `HTTP Proxy: http://proxy.orb.internal:8305`; `vmgr` imports `res_9_nsearch`
  and `SCDynamicStoreCopyProxies` and contains `ProxyManager` and
  `ListenDNS`. [G][B]
- **Address pools avoid conflicts.** Docker is given 30 `/24` pools spread
  across `192.168.x.0/24` plus one IPv6 `/56`. [G]

## 10. Container management

The Docker engine is upstream, version 29.8.2 (containerd `ee2735368117`,
runc `29dd3dc2b13b`), cgroup v2 with the `cgroupfs` driver, seccomp builtin,
`json-file` logging, `Experimental: true`. [G] It runs inside the VM as a
machine that `scon` starts: the log reads `starting container container=docker`.
The author describes `scon`'s lineage: "It currently uses LXC as the runtime
but that's being replaced as well. For containers we run a standard Docker
engine inside a special machine." [D] Whether 2.2.5 still uses LXC was not
determined.

`vmgr` also embeds `k8s.io/client-go@v0.33.1` and `github.com/moby/buildkit`
and manages `~/.kube/config`; the guest image contains an `orb-coredns`
manifest. Kubernetes is disabled on this machine (`k8s.enable: false`).

Settings exposed by `orbctl config show` that bear on performance:
`cpu`, `memory_mib`, `machine.docker.cpu`, `machine.docker.memory_mib`,
`machine.docker.disk_bytes`, `network.subnet4`, `network_bridge`,
`rosetta`, `power.pause_in_sleep`, `docker.expose_ports_to_lan`. [R]

## 11. What this adds to the register

As of the scorecard, Micropod leads on published-TCP throughput (8,046 vs
7,207 MiB/s, all 16 pairs) and CI time (5.65 vs 22.55 s). OrbStack leads on
fresh-request latency during downloads (p95 5.24 vs 9.94 ms), quiet in-guest
calls (HTTP 38.1 vs 72.6 µs), single-DNS p95 (77 vs 118 µs) and the
sustained sibling transfer (13,496 vs 9,582 MiB/s). The latency lead depends
on the workload: under Docker CPU sets and under the 16 KiB kernel, OrbStack's
fresh p95 was 56.6 and 51.8 ms against Micropod's 12.1 and 9.7 ms.

Nothing below attributes a scorecard gap to a mechanism. Each item says
which register row it bears on and whether the row already covers it.

**Latency without thread priority (rows 228.01, 228.03).** Row 228.01 found
that the Interactive launchd role lowers fresh p95 from 10.19 to 6.36 ms at a
throughput cost. OrbStack reaches 5.24 ms with its vCPU threads at priority
31 and six I/O workers at 20, so it does not get that latency from thread
priority. What its guest does instead is remove background work and
accounting: `cgroup.memory=nokmem,nosocket` on the command line,
`vm.compaction_proactiveness=0`, `vm.watermark_boost_factor=0`,
`vm.overcommit_memory=1`, and RT throttling switched off. The compaction and
watermark settings appear in no other register document. They are
command-line and sysctl changes, which makes them cheap to screen on the
fresh-request workload.

**Quiet service calls and syscall cost (row 235.06).** OrbStack's in-guest
advantage cannot come from its host path. Row 235.06 already records that
Micropod's kernel compiles out KPTI, so OrbStack's `meltdown: Not affected`
is parity, not a difference. The remaining kernel-side candidates are
`nokmem,nosocket`, `slab_min_order=2` and `swiotlb=noforce`. The first turns
off memcg accounting for kernel allocations and socket buffers, which is the
one of the three with work on the syscall and packet paths.

**Socket buffers (row 230.11).** OrbStack's guest allows `net.core.rmem_max`
and `wmem_max` of 7.5 MB and autotunes TCP receive up to 32 MB.

**Offloads and rings (rows 229.01, 231.01, 231.02, 239.04).** OrbStack's
guest NICs are split-ring, single-queue, EVENT_IDX and RING_RESET, with
TSO4/TSO6 in both directions and checksum offload. They do not negotiate
MRG_RXBUF or packed rings. The host port runs at MTU 1500, in line with row
229.01, which measured no gain from MTU 9000.

**Swap and reclaim (rows 238.14, 238.17, 239.06).** Row 238.14 plans a zram
arm. OrbStack's recipe is a starting point for it: lz4 zram sized to the
VM's memory, `swappiness` 20, `page-cluster` 1, priority 32767 ahead of a
1 GiB disk swap at priority 1. For host reclaim it negotiates free-page
reporting (feature bit 5) on a balloon device it implements itself. Rows
238.17 and 239.06 ask for a host-footprint change from the stock VZ
balloon; whether that device offers page reporting was not checked here.

**Second VMM decision (rows 240.01–07).** OrbStack is an existence proof
with a measurable shape: one process, four default-priority vCPU threads
with about 97% of their time in user mode, twelve virtio-mmio devices, host
services on gVisor's network stack, and a balloon with page reporting.

**Not applicable (row 230.09).** That row found vectored I/O slower on the
relay. OrbStack's `recvMMsgDispatcher` and `readVDispatcher` sit on the
packet link between its network stack and the VM, not on a stream relay, so
they are not evidence either way.

**Not measured.** OrbStack documents "up to 45 Gbps" between macOS and
containers. Nothing here confirms or refutes it.

## 12. Unknowns

Settleable with a decompiler pass (licensed Hopper or Ghidra configured for
REA), or with a privileged guest shell:

- The balloon's policy: target computation, when the host drops pages.
- The virtiofs cache policy and the constants behind "node trim".
- Which vmnet keys `vmgr` sets, and their values.
- The `/dev/krpc` protocol and what `orb_rvk_set_key` sets.
- What, if anything, replaces KPTI.
- When `swext.vzfMachine` is selected instead of the Rust backend.
- The purpose of `kernel.ri` (a 6.7.11-orbstack+ kernel from April 2024) and
  `rpack` (a cpio archive holding a single static `sbin/init`). They look
  like a recovery environment; that is a guess.
- The guest's own mount table and the virtiofs mount options.
- The low priority (20) of the worker threads: deliberate or incidental.

One observation without an explanation: the log shows
`scon: failed to mount rootfs … open tree in mount ns: no such process` 206
times in 18 hours, and the kernel warned four times that an overlayfs
upperdir was in use by another mount.

## 13. Second pass: sockets, networking, virtualisation

Collected after the first draft from the same sources plus two more: a
read-only HTTP `GET` to each Unix socket with `curl`, and one more
short-lived unprivileged container (`--hostname orbprobe`). Grade I means
read from the shipped guest image (`rootfs.img` strings).

### Sockets

Every Unix socket lives in `~/.orbstack/run`, is mode `srwxr-xr-x`, and is
held by `vmgr`. Protocol is what the socket answered when probed. [R]

| Socket | Answered with | Role |
|---|---|---|
| `docker.sock` | `HTTP/1.1 200 OK`, `Api-Version: 1.56`; no HTTP/2 | Docker API, proxied to the engine in the VM |
| `vmcontrol.sock` | `HTTP/1.1 405`, `Accept-Post: application/json` | control API used by the GUI and CLI |
| `sconrpc.sock` | same `405` signature | RPC for the guest side |
| `sconrpc2.sock` | neither HTTP/1.1 nor HTTP/2: binary framing | second-generation RPC for the guest side |
| `sconssh.sock`, `sconssh-public.sock` | an SSH banner | SSH for machines |
| `nfs.sock` | binary stream | Linux-to-Mac NFS |
| `127.0.0.1:32222` (IPv4 and IPv6 loopback) | SSH | `orbctl ssh` endpoint |
| `127.0.0.1:49259` | NFS | the Mac kernel NFS client's endpoint |

`vmgr` links the JSON-RPC 2.0 library `github.com/creachadair/jrpc2`, which
fits the POST-only JSON signature of `vmcontrol.sock` and `sconrpc.sock`.
[B][R] The NFS listener starts with 128 KiB buffers; the established side
had autotuned to 1.7 MB receive and 3.4 MB send. [R]

- **No UDP sockets on macOS.** Neither OrbStack process owned a UDP socket.
  DNS, NTP, the proxy and ping are answered inside `vmgr`'s user-space stack;
  mDNS goes through the system daemon (`DNSServiceQueryRecord`). [R][B]
- **Kernel-control sockets.** `vmgr` holds two `com.apple.netsrc` sessions
  (the system's network-policy control) and one
  `com.apple.userspace_ethernet`, a virtual Ethernet port. [R]
- **Descriptors, not connections.** `vmgr` imports `xpc_fd_create`,
  `xpc_fd_dup`, `xpc_shmem_create` and `xpc_shmem_map`, and has
  `runSshProxyFdpass` and `sshProxySendFd`: the CLI hands file descriptors
  to `vmgr` over XPC, and pumps with a socketpair at one end
  (`Pump2SpTcpTcp`, `Pump2SpTcpUnix`, `Pump2SpUnixUnix`) move the bytes. [B]
- **Unix-socket NAT.** `UnixNATForward`, `StartUnixVsockHostForward` and
  `ListenUnixNATForward`, with `host-unix forward` log lines: a Mac Unix
  socket bind-mounted into a container is emulated by a socket in the guest
  that forwards to the Mac one. [B][R]
- **SSH agent forwarding.** `ListenHostSSHAgent`, `Pump2SshAgent`, the
  guest path `/opt/orbstack-guest/run/host-ssh-agent.sock`. [B][I]
- **The published-port path has three hops.** Host listener, then the
  guest agent dials `container_ip:port`, then the container. The log shows
  the agent retrying (`failed to dial local (1)`, `(2)`) and logging every
  failure at error level: 1,679 failures in 18 hours, most to
  `192.168.215.3:5432` while PostgreSQL was not yet listening. [R]
- **Datagrams between the host stack and the VM** ride a pair of connected
  Unix datagram sockets (`NewUnixgramPair`), with a callback variant
  (`StartCallbackPair`, `cblink`). [B]
- **Connection hygiene.** `TCPConn.tryAbort` (by its name, a reset rather
  than an orderly close), `TCPListener.SyscallConn` and `File` (raw socket
  options). [B]

### Networking

**The service network.** A private `/24`, `0.250.250.0/24` (IPv6
`fd07:b51a:cc66:f0::/64`), inside 0.0.0.0/8 so it cannot collide with a real
network. Addresses as resolved from inside a container and as named in the
binary and the log: [G][B][R]

| Name | IPv4 | IPv6 |
|---|---|---|
| `gateway.docker.internal` | `0.250.250.1` | `fd07:b51a:cc66:f0::1` |
| the guest itself (target of `vmgr`'s "dial guest" log lines) | `0.250.250.2` | `…::2` |
| `proxy.orb.internal`, and the container's DNS server | `0.250.250.200` | |
| `host.docker.internal`, `host.internal` | `0.250.250.254` | `…::fe` |

The binary also names `.10` and `.201`; their roles were not determined.
Containers reach these addresses through the ordinary default gateway
(`ip route get 0.250.250.200` goes via `192.168.215.1`). [G]

**Services on it** (Go `Listen*` names in `vmgr/vnet/services`): DNS with a
reverse-name cache, NTP, `hcontrol` (the guest's control API, also on UDP
and UDP broadcast), HID, serial ports, host disks, host SSH, host SSH
agent, a remote-Docker-context endpoint, sleep assertions (`caffeinate`),
ready events, and an HTTP CONNECT plus SOCKS5 proxy written by hand
(`readSOCKSRequest`, `writeUpstreamRequest`). [B]

**Port forwarding is guest-driven.** The guest asks the host to
`StartForward`, `StopForward` or `ResetForwards` through `HcontrolServer`
when Docker reports a port change. `ForwardLanPacket`,
`PollLanMdnsPackets`, `SetLanMdnsForwarding` and `MdnsSendCacheFlush` carry
the "Expose ports to LAN" setting, including Bonjour reflection. [B]

**Limits exist but are not visible.** `shouldLogSetupLimit` and
`shouldLogUDPConntrackLimit` rate-limit a log line when TCP forward setups
or the UDP proxy's connection table hit a cap. The caps are constants in
the binary. [B]

**Host stack and NICs.** gVisor's stack (`gonet.ListenTCP`,
`DialTCPWithBind`, `NewViewWriter`; `dglink` with `recvMMsgDispatcher` and
`readVDispatcher`), packets handed to the VM through
`rsvm_network_write_packet`. `RouteMon.ContainsIP` checks whether a target
falls in a monitored subnet before bridging. [B]

**Container side.** `eth0` has MTU 1500 and `tx_queue_len` 0. Its MAC was
`2a:fc:…`, not Docker's `02:42:` scheme, and the log shows OrbStack's agent
adding and removing the `docker0` network itself (142 times in 18 hours
under a benchmark workload). [G][R] The bridge is `192.168.215.0/24`, gateway
`.1`, `enable_ip_masquerade: true`, IPv6 off. [G]

**Names.** `kubernetes.docker.internal` is NXDOMAIN with Kubernetes off. A
`--hostname` given to `docker run` is not registered either; only Docker's
own names are. [G] The guest image ships iptables and nftables
(`libnftables.so.1.1.0`, libnetwork's nftables driver). [I]

**GUI.** It uses Network.framework's Swift API: `NWListener` with a Bonjour
`service` and TLS, `NWConnection`, TCP, TLS and UDP options. It held no IP
sockets at idle, so the listener is created on demand; its purpose was not
determined. [B][R]

### Virtualisation

- **Hypercall device I/O.** `HVC IO: dev_id=` and `hvc.rs` files under
  `virtio/{fs,block,console,vsock}`: a second transport next to the virtio
  rings, used for messages. [B]
- **Its own virtio core.** Split rings with queue size and alignment
  checks, *deferred used descriptors* (completions are batched), and IRQ
  resample events. [B]
- **Its own GICv3.** MMIO and system-register accesses are traced per PE;
  distributor base is configured at creation; vtimer masking goes through
  `hv_vcpu_get/set_vtimer_mask`. [B]
- **State dumps on vCPU errors** cover EL2 and EL1 registers (`CPTR_EL2`,
  `TCR_EL2`, `MDCR_EL2`, `VBAR_EL2`, `ELR_EL2`, `FAR_EL1`, `TPIDR_EL1`). [B]
- **A socket multiplexer, not virtio-vsock.** CIDs and ports, operations
  such as `OP_RW` and `OP_RST`, DGRAM listen, accept and sendto, proxy
  create and connect, per-protocol handlers for TCP, UDP and UNIX, plus
  `timesync` and `reaper` threads. [B]
- **Change notifications from the Mac side.** `virtio::fs::macos` contains
  `vnode_poll`, `syncopens`, `passthrough` and `mounts_boundaries`. [B]
- **Profiling built in.** `machine.StartProfile`, vCPU sampling with an
  overhead breakdown ("suspend + host sampling + resume + guest sampling"),
  a Firefox-profiler exporter, ktrace. Profiles are encrypted
  (`profenc`: KEM, KDF, AEAD suites). [B]
- **Nested-virtualisation code** is present (`supportsNestedVirt`, "nested
  EL2 vectors"). [B]
- **The second backend's spec** (`vmm.VzSpec`) has fields `cpus`, `memory`,
  `kernel`, `kernelCsmap`, `cmdline`, `initrd`, `console`, `mtu`,
  `macAddressPrefix`, `network`, `networkNat`, `rosetta`, `virtiofs`, and
  `diskData`, `diskSwap`, `lineSize`. [B]

**Guest software.** The guest image is an Alpine/musl userland with
busybox and eudev. Its root tree has `docker` at `/`, the mount point of the
data volume. Programs visible in it, beyond `vinit` and Docker's own: [I]

| Name | What the evidence says |
|---|---|
| `scon`, `scon-agent`, `scon-fork` | the machine runtime and its agent; the fork fits the author's "LXC, being replaced" |
| `runc-wrapper` | wraps `runc`; matches the agent's `failed to mount rootfs` log lines |
| `pstub` | the port stub Docker uses as its userland proxy (`/run/pstub.sock`) |
| `serialclient` | Rust component that creates the Mac-side serial devices |
| `hidserver` | opens `/dev/uhid` in the guest to create virtual HID devices |
| `simplevisor`, `rinit`, `rstub` | a supervisor and two init helpers; roles not determined |
| `sftp` | file transfer for `orbctl push`/`pull` |
| `starry` | not determined |
| `wormhole`, `wormhole-attach`, `-stub`, `-rootfs`, `-overlay`, `-unified` | a file-access channel with a stub under `/dev/shm`; purpose inferred |
| `qemu-x86_64` | user-mode emulator, alongside Rosetta |
| `bin-hiprio` | a directory in the image's path lists; contents not readable |

### Open after this pass

- Roles of `0.250.250.10` and `.201`.
- What `wormhole`, `starry`, `simplevisor` and `bin-hiprio` are.
- The caps behind `shouldLogSetupLimit` and `shouldLogUDPConntrackLimit`.
- What the GUI's on-demand listener serves.
- Why the guest agent, not Docker's driver, creates container interfaces.

## 14. Hardware: what reaches the guest and what does not

An audit of every sense of "hardware acceleration" against evidence: the
host's feature sysctls, the guest's `/proc/cpuinfo` and `/sys` read inside
a container, `ioreg`, and the binaries. The short answer is that OrbStack
uses no hardware trick for containers that Micropod's own VM could not
also use. What it does is pass the useful CPU features through, expose a
few real devices, and withhold the rest.

### CPU features seen by a container

| Group | Examples | Host | Guest |
|---|---|---|---|
| Crypto | AES, PMULL, SHA1, SHA256, SHA512, SHA3 | yes | yes |
| Checksum and atomics | CRC32, LSE | yes | yes |
| Floating point and ML | FP16, dot product, FHM, RDM, JSCVT, FCMA, BF16, I8MM, AFP, EBF16 | yes | yes |
| Memory and ordering | DIT, RCPC, DC PoP, SB, FlagM2, FRINTTS | yes | yes |
| Counter virtualisation | ECV | yes | forced on by the command line |
| Matrix and vector | SME, SME2, SME2p1 | yes | no (`arm64.nosme`) |
| Security | PAuth, PAuth2, FPAC, BTI, MTE | yes | no |
| Other | CSSC, HBC, RPRES, WFxT, LSE2 | yes | no |

The guest's CPU identity is the framework's fixed one: MIDR `0x610f0000`,
Apple implementer, part number zero. [G] Containers therefore get
hardware AES, SHA and CRC (used by TLS, zstd and lz4) and the I8MM and BF16
matrix instructions (used by ML runtimes), but not SVE or SME.

### Not present in the guest

- **GPU.** No virtio-gpu and no DRM device; `/sys/class/drm` holds only
  `version`. [G]
- **Performance counters.** No PMU driver: zero `armv8_pmuv3` symbols, and
  the event sources are breakpoint, kprobe, software, tracepoint and
  uprobe. `perf_event_paranoid` is 2. [G]
- **Nested virtualisation and device passthrough.** KVM is compiled into
  the guest kernel (996 `kvm_*` symbols, VHE variant), but there is no
  `/dev/kvm`, and no VFIO or IOMMU groups. The usual cause of a missing
  `/dev/kvm` is EL2 not being exposed, which I could not read directly. [G]
- **Hardware video.** No VideoToolbox or media framework is linked by any
  OrbStack component. [B]

### Hardware that does reach the guest

| Hardware | Path | Grade |
|---|---|---|
| Audio out and in | virtio-snd, one ALSA card with a capture and a playback PCM; `vmgr` references `VZHostAudioOutputStreamSink` and runs an AUHAL output unit; its one realtime thread is CoreAudio's | G, B, R |
| USB devices | a custom xHCI controller (`4000c000.usb`, two root hubs) over IOUSBHost; nothing attached at the time | G, B |
| Human-interface devices | IOHIDManager in `vmgr`, `/dev/uhid` in the guest; one YubiKey present as `hidraw0` | B, G |
| Whole disks and images | `hostdisks` and `disksrv`, NBD or loop in the guest, privileged helper for whole disks | B |
| SSD trim | DISCARD and WRITE_ZEROES negotiated on every virtio-blk device | G |
| Entropy | `virtio_rng.0` is the guest's only hardware RNG, fed from the host | G |
| Host clock | `ptp0`, clock name "KVM virtual PTP": the guest reads host time through a paravirtual call | G |
| Serial ports | `serialclient` creates Mac-side tty devices and bridges them | R |

### Topology given to the guest

`vmgr` reads the host's `hw.perflevel0.*` values and builds matching device
tree cache nodes. [B] The result as the guest sees it: [G]

| Level | Host "Super" tier | Guest |
|---|---|---|
| L1 data | 128 KiB | 128 KiB |
| L1 instruction | 192 KiB | 192 KiB |
| L2 | 16 MiB per 6 cores | 16 MiB shared by all 4 vCPUs |
| L3 | none reported | 64 MiB, synthetic |
| cache line | 128 bytes | 128 bytes |

Each vCPU reports `cpu_capacity` 1024. The machine has two tiers
(`Super`, 6 cores; `Performance`, 12 cores).

### QoS and core tiers

The thread priorities in section 3 are the base priorities Darwin gives
its QoS classes: 4 for BACKGROUND, 20 for UTILITY, 31 for DEFAULT. On that
reading OrbStack runs its vCPUs at default QoS, its virtio-fs and block
workers at utility QoS, and cache trimming in the background. On a
two-tier machine macOS tends to place utility work on the lower tier, so
I/O workers would land on the slower cores and vCPUs on the faster ones.
That placement is an inference; the priorities are measured. Every VMM
thread is time-sharing. The only realtime thread in the process is
CoreAudio's.

### GPU on the Mac side only

The GUI holds a live `AGXDeviceUserClient` and an `IOSurfaceRootUserClient`.
It links `MTLCopyAllDevices`, a Metal render-pipeline descriptor and
vertex descriptor, a display-link callback, and a shader library that
converts YCbCr to RGB for BT.601, BT.709 and BT.2020 in 4:2:0 and 4:2:2,
so it renders video-like frames on the GPU. `vmgr` holds one user client,
`RootDomainUserClient`, for its power assertion. [R][B]

### Interfaces for other software stacks

The guest kernel offers Android's binder devices (`binder`, `hwbinder`,
`vndbinder`), `udmabuf` and `ntsync`, and the image ships V4L2 and UVC
modules. These support Android emulators and Windows software in
containers; none of them is an accelerator. [G][I]

### Open after this pass

- Whether KVM is absent because EL2 is withheld.
- What the GUI's GPU-rendered frames are.

## 15. Network throughput, measured

A small controlled measurement, not benchmark-grade: no pairing, busybox
`nc` streaming `/dev/zero` as the server, and a short Go client on the Mac
reading with 256 KiB buffers for four seconds per run. One warm-up run was
discarded before each series. OrbStack was idle, with no other containers,
for every run. `vmgr` CPU covers the whole process, vCPU threads included;
the Mac client's CPU is not counted. [R]

| Path | Streams | MiB/s (runs) | `vmgr` CPU-s per GiB | Busiest threads over 4 s |
|---|---|---|---|---|
| Published port | 1 | 10,150 to 10,708 (4) | 0.41 | one host thread 3.7 s; one vCPU 3.4 s |
| Published port | 4 | 6,990 to 7,400 (4) | 0.81 | one host thread 3.9 s; one vCPU 3.7 s; four more near 1 s |
| Direct container IP | 1 | 205 (1) | 6.1 | one vCPU 4.0 s |
| Direct container IP | 4 | 405 (1) | 2.7 | one vCPU 4.0 s |

**The published-port path never touches vmnet.** About 68 GiB went through
it and the vmnet ports moved under 60 KB between them. The path is entirely
inside `vmgr`: the Mac's TCP, the pump, the gVisor stack, then the Rust
device over the host-internal virtio-net port.

**One vCPU is the single-stream ceiling.** A vCPU thread ran at about 86%
of a core for the whole single-stream run, and 10 GiB/s is where it lands.

**More streams lower total throughput and double the CPU per byte.** Four
streams gave 6,990 to 7,400 MiB/s at 0.81 CPU-s per GiB. One of the four
streams received about two-thirds of the others each time (about 1,300
against 1,950 MiB/s). Every virtio-net device is single-queue, so guest
receive processing has one queue to work with.

**The direct container-IP path is slow.** It ran at 205 MiB/s on one stream
with a vCPU thread pinned, and in the four-stream run two streams received
nothing within four seconds. Its traffic does cross vmnet: 4.8 GB on
`vmenet1` during the direct runs. The wiring is a second vmnet port bridged
into the VM: while a container runs the Mac holds a route
`192.168.215/24 → bridge101`, `bridge101` takes the address
`192.168.215.0/24` (it holds `192.168.64.1/24` when no container runs), and
`vmenet1` is its only member. The route disappears when the last container
stops.

Why the direct path is slow was not determined. It carries 1500-byte frames
one at a time across the VM boundary, where the published path carries large
segments, and it pins a vCPU. That fits per-packet exits into `vmgr`, but it
is a hypothesis.

Against the scorecard: OrbStack's 32-stream published figures there are
7,207, 8,133 and 8,996 MiB/s, in line with the four-stream result here. The
scorecard has no single-stream OrbStack figure to set beside the 10 GiB/s.

### Open after this pass

- Why the direct container-IP path pins a vCPU at about 200 MiB/s.
- Whether Micropod's published port also reaches about 10 GiB/s on a single
  stream; the scorecard only reports 32-stream runs.

## Appendix: reproducing the reads

```sh
# Binary-level (REA; each CLI run is a fresh session)
npx rea-agents@6.4.0 inspect-artifact /Applications/OrbStack.app --format json
npx rea-agents@6.4.0 project-apple-application-graph <wrapped-inventory.json>
npx rea-agents@6.4.0 trace-dylib-resolution /Applications/OrbStack.app --format json
npx rea-agents@6.4.0 inspect-macho ".../OrbStack Helper.app/Contents/MacOS/OrbStack Helper"
npx rea-agents@6.4.0 inspect-signature ".../OrbStack Helper.app"

# Runtime
ps -M -p "$(pgrep -f 'OrbStack Helper vmgr')"; sample "$pid" 1; vmmap -summary "$pid"
grep '🌲 vmgr' ~/.orbstack/log/vmgr.log | head -40

# Guest (short-lived, unprivileged)
docker -H unix://"$HOME/.orbstack/run/docker.sock" run --rm --network none \
  --cap-drop ALL --security-opt no-new-privileges alpine:3.23 \
  sh -c 'cat /proc/cmdline; cat /sys/bus/virtio/devices/virtio0/features'

# Kernel
strings -a .../assets/release/arm64/kernel | grep -m1 'Linux version'
```

REA evidence identifiers from this session: artifact inventory
`ev_908ce44cf4aa…` (inspection `ai_db5773c9e60b…`), Apple application graph
`aap_9d6f4f4226e9…`, bundle manifest `5220bc26bd94…`.
